import Darwin
import Foundation

public struct ProjectCommandResult: Sendable, Equatable {
    public let output: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let outputWasTruncated: Bool
    public let originalArguments: [String]
    public let effectiveArguments: [String]
    public let rtkApplied: Bool
}

public enum ProjectCommandError: Error, Sendable { case invalid; case unavailable }

/// Executes one host-approved argv invocation. A command gets its own process group, so its
/// cancellation never affects another conversation using the shared connection runtime.
public actor ProjectCommandRunner {
    private final class Invocation: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var didTimeOut = false
        init(pid: pid_t) { self.pid = pid }
        func markTimedOut() { lock.lock(); didTimeOut = true; lock.unlock() }
        func timedOut() -> Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }
    }

    private let root: URL
    private let rtkExecutablePath: String?
    private var invocations: [UUID: Invocation] = [:]

    public init(projectURL: URL, rtkExecutablePath: String? = "/opt/homebrew/bin/rtk") {
        root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        if let rtkExecutablePath, FileManager.default.isExecutableFile(atPath: rtkExecutablePath) {
            self.rtkExecutablePath = rtkExecutablePath
        } else if rtkExecutablePath == "/opt/homebrew/bin/rtk" {
            self.rtkExecutablePath = Self.discoverRTK(projectRoot: root)
        } else {
            self.rtkExecutablePath = nil
        }
    }

    public var availableRTKPath: String? { rtkExecutablePath }

    private static func discoverRTK(projectRoot: URL) -> String? {
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let candidates = ["/opt/homebrew/bin/rtk", "/usr/local/bin/rtk"] + pathEntries.map { "\($0)/rtk" }
        return candidates.first { candidate in
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            return url.path.hasPrefix("/") && !url.path.hasPrefix(projectRoot.path + "/") && FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    public func run(
        arguments: [String],
        runID: UUID = UUID(),
        timeout: TimeInterval = 120,
        maxOutputBytes: Int = 65_536
    ) async throws -> ProjectCommandResult {
        guard let executable = arguments.first,
              executable.hasPrefix("/"),
              arguments.count <= 64,
              !arguments.contains(where: { $0.utf8.contains(0) }),
              timeout > 0, timeout <= 1_800,
              maxOutputBytes > 0, maxOutputBytes <= 1_048_576 else { throw ProjectCommandError.invalid }

        let command = Self.effectiveArguments(for: arguments, rtkExecutablePath: rtkExecutablePath)
        let pipe = try Self.makePipe()
        var spawned = false
        defer {
            if !spawned {
                close(pipe.read)
                close(pipe.write)
            }
        }
        let pid = try Self.spawn(executable: command.arguments[0], arguments: command.arguments, workingDirectory: root.path, outputFD: pipe.write)
        spawned = true
        close(pipe.write)
        let invocation = Invocation(pid: pid)
        invocations[runID] = invocation

        let output = OutputCollector(limit: maxOutputBytes)
        let readerGate = ReaderGate()
        let reader = FileHandle(fileDescriptor: pipe.read, closeOnDealloc: true)
        reader.readabilityHandler = { handle in
            readerGate.lock.lock()
            defer { readerGate.lock.unlock() }
            guard !readerGate.finished else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { output.append(chunk) }
        }
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            await self?.timeOut(runID: runID)
        }
        defer {
            watchdog.cancel()
            reader.readabilityHandler = nil
            try? reader.close()
            invocations.removeValue(forKey: runID)
        }

        // waitpid runs on a dispatch worker. Polling its synchronized completion also observes a
        // cancelled Swift turn even on runtimes that delay cancellation-handler delivery.
        let exitState = ExitState()
        Self.waitForExit(pid, into: exitState)
        let cancellation = CancellationState()
        let status = await withTaskCancellationHandler(operation: {
            while exitState.status == nil {
                if Task.isCancelled, cancellation.markAndCheckFirst() {
                    Self.terminateProcessGroup(invocation.pid)
                }
                await Self.pollDelay()
            }
            return exitState.status ?? 0
        }, onCancel: {
            if cancellation.markAndCheckFirst() {
                Self.terminateProcessGroup(invocation.pid)
            }
        })
        let capturedOutput = readerGate.lock.withLock { () -> (string: String, truncated: Bool) in
            readerGate.finished = true
            reader.readabilityHandler = nil
            Self.drainAvailable(fd: pipe.read, into: output)
            return output.snapshot()
        }
        return ProjectCommandResult(output: capturedOutput.string, exitCode: Self.exitCode(from: status), timedOut: invocation.timedOut(), outputWasTruncated: capturedOutput.truncated, originalArguments: arguments, effectiveArguments: command.arguments, rtkApplied: command.applied)
    }

    public func cancel(runID: UUID) {
        guard let invocation = invocations[runID] else { return }
        Self.terminateProcessGroup(invocation.pid)
    }

    /// Used only when the entire connection runtime is torn down.
    public func cancelAll() {
        for invocation in invocations.values { Self.terminateProcessGroup(invocation.pid) }
    }

    private func timeOut(runID: UUID) {
        guard let invocation = invocations[runID] else { return }
        invocation.markTimedOut()
        Self.terminateProcessGroup(invocation.pid)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ProjectCommandError.unavailable }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        return (descriptors[0], descriptors[1])
    }

    static func effectiveArguments(for arguments: [String], rtkExecutablePath: String?) -> (arguments: [String], applied: Bool) {
        guard let executable = arguments.first,
              let rtkExecutablePath,
              ["/usr/bin/git", "/bin/ls", "/opt/homebrew/bin/rg"].contains(executable) else {
            return (arguments, false)
        }
        return ([rtkExecutablePath, URL(fileURLWithPath: executable).lastPathComponent] + Array(arguments.dropFirst()), true)
    }

    private static func spawn(executable: String, arguments: [String], workingDirectory: String, outputFD: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw ProjectCommandError.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, outputFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputFD, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addclose(&actions, outputFD) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) == 0 else { throw ProjectCommandError.unavailable }
        var signalMask = sigset_t()
        var defaultSignals = sigset_t()
        sigemptyset(&signalMask)
        sigfillset(&defaultSignals)
        let flags = Int16(truncatingIfNeeded: POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else { throw ProjectCommandError.unavailable }
        let cArguments = arguments.map { value in value.withCString { strdup($0) } }
        defer { cArguments.forEach { free($0) } }
        var argv = cArguments + [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, &argv, environ) == 0 else { throw ProjectCommandError.unavailable }
        return pid
    }

    private static func waitForExit(_ pid: pid_t, into state: ExitState) {
        DispatchQueue.global(qos: .userInitiated).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            state.finish(status)
        }
    }

    private static func terminateProcessGroup(_ pid: pid_t) {
        let descendants = childProcesses(of: pid)
        // Freeze the shell and its jobs before killing. A graceful TERM can let an interpreter
        // resume and execute a following command after its background child receives a signal.
        signal(pid: pid, descendants: descendants, signal: SIGSTOP)
        signal(pid: pid, descendants: descendants, signal: SIGKILL)
    }

    private static func signal(pid: pid_t, descendants: [pid_t], signal: Int32) {
        _ = kill(-pid, signal)
        _ = kill(pid, signal)
        for child in descendants.reversed() { _ = kill(child, signal) }
    }

    private static func childProcesses(of parent: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let byteCount = Int32(buffer.count * MemoryLayout<pid_t>.stride)
        let count = proc_listchildpids(parent, &buffer, byteCount)
        guard count > 0 else { return [] }
        let children = buffer.prefix(Int(count)).filter { $0 > 0 }
        return children.flatMap { childProcesses(of: $0) } + children
    }

    private static func pollDelay() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(10)) {
                continuation.resume()
            }
        }
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    private static func drainAvailable(fd: Int32, into output: OutputCollector) {
        let originalFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }
        var bytes = [UInt8](repeating: 0, count: 8_192)
        // A detached descendant may keep writing after its parent has exited. Do not turn final
        // draining into an unbounded loop; normal live reads already collected prior output.
        for _ in 0..<64 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { return }
            output.append(Data(bytes.prefix(Int(count))))
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - data.count
        if remaining > 0 { data.append(chunk.prefix(remaining)) }
        if chunk.count > remaining { truncated = true }
    }
    func snapshot() -> (string: String, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), truncated)
    }
}

private final class ReaderGate: @unchecked Sendable {
    let lock = NSLock()
    var finished = false
}

private final class ExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? { lock.withLock { value } }
    func finish(_ status: Int32) { lock.withLock { value = status } }
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false
    func markAndCheckFirst() -> Bool {
        lock.withLock {
            guard !sent else { return false }
            sent = true
            return true
        }
    }
}
