import CoreServices
import Foundation

/// A retained callback bridge keeps FSEvents from holding an unowned reference to
/// the main-actor watcher while its dispatch queue drains during window teardown.
private final class ContextEventBridge: @unchecked Sendable {
    let handler: @Sendable ([String], Bool) -> Void
    init(handler: @escaping @Sendable ([String], Bool) -> Void) { self.handler = handler }
}

private func retainContextEventBridge(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let info else { return nil }
    _ = Unmanaged<ContextEventBridge>.fromOpaque(info).retain()
    return info
}

private func releaseContextEventBridge(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<ContextEventBridge>.fromOpaque(info).release()
}

private func receiveContextEvents(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ pathsPointer: UnsafeMutableRawPointer,
    _ flagsPointer: UnsafePointer<FSEventStreamEventFlags>,
    _ idsPointer: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let bridge = Unmanaged<ContextEventBridge>.fromOpaque(info).takeUnretainedValue()
    let values = Unmanaged<CFArray>.fromOpaque(pathsPointer).takeUnretainedValue() as NSArray
    let paths = values.compactMap { $0 as? String }
    let rescanMask = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs |
        kFSEventStreamEventFlagUserDropped |
        kFSEventStreamEventFlagKernelDropped |
        kFSEventStreamEventFlagRootChanged
    )
    let mustRescan = (0..<count).contains { flagsPointer[$0] & rescanMask != 0 }
    if paths.count == count { bridge.handler(paths, mustRescan) }
}

/// Coalesces recursive filesystem notifications and forwards only paths which can
/// change Agent Context. It never writes to either watched location.
@MainActor
final class AgentContextWatcher {
    var onChange: (([URL]) -> Void)?

    private let projectURL: URL
    private let globalStoreURL: URL
    private let watchedPaths: [String]
    private let queue = DispatchQueue(label: "FSCode.AgentContextWatcher")
    private lazy var bridge = ContextEventBridge { [weak self] paths, mustRescan in
        Task { @MainActor [weak self] in self?.receive(paths, mustRescan: mustRescan) }
    }
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var changedPaths: Set<String> = []
    private var knownSourcePaths: Set<String> = []
    private var isActive = false

    init(projectURL: URL, globalStoreURL: URL) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.globalStoreURL = globalStoreURL.resolvingSymlinksInPath().standardizedFileURL
        let globalWatchRoot = Self.nearestExistingDirectory(to: self.globalStoreURL)
        watchedPaths = Array(Set([self.projectURL.path, globalWatchRoot.path]))
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(bridge).toOpaque(),
            retain: retainContextEventBridge,
            release: releaseContextEventBridge,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            receiveContextEvents,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else { return }
        stream = created
        isActive = true
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        isActive = false
        pending?.cancel()
        pending = nil
        changedPaths.removeAll()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func isRelevant(_ url: URL) -> Bool {
        isRelevant(path: url.standardizedFileURL.path)
    }

    func updateKnownSources(_ urls: [URL]) {
        knownSourcePaths = Set(urls.map { $0.standardizedFileURL.path })
    }

    nonisolated static func isRelevantChange(path: String, projectPath: String, globalPath: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let global = URL(fileURLWithPath: globalPath).standardizedFileURL.path
        if standardized == global || standardized.hasPrefix(global + "/") || global.hasPrefix(standardized + "/") {
            return true
        }
        guard standardized == project || standardized.hasPrefix(project + "/") else { return false }
        let relative = standardized == project ? "" : String(standardized.dropFirst(project.count + 1))
        let relativeComponents = Set(relative.split(separator: "/").map(String.init))
        let ignored = [".git", ".build", "node_modules", "dist", "vendor", "DerivedData"]
        guard ignored.allSatisfy({ !relativeComponents.contains($0) }) else { return false }
        if relative == ".fs" || relative == ".fs/context" || relative.hasPrefix(".fs/context/") { return true }
        if relative == ".cursor" || relative == ".cursor/rules" || relative.hasPrefix(".cursor/rules/") { return true }
        if relative == ".claude" || relative == ".claude/rules" || relative.hasPrefix(".claude/rules/") { return true }
        if relative == ".github" || relative == ".github/instructions" || relative.hasPrefix(".github/instructions/") { return true }
        if relative == ".github/copilot-instructions.md" { return true }
        let name = URL(fileURLWithPath: relative).lastPathComponent
        return ["AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.local.md", ".cursorrules"].contains(name)
    }

    private func isRelevant(path: String) -> Bool {
        if Self.isRelevantChange(path: path, projectPath: projectURL.path, globalPath: globalStoreURL.path) { return true }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return knownSourcePaths.contains { source in
            source == standardized || source.hasPrefix(standardized + "/") || standardized.hasPrefix(source + "/")
        }
    }

    private func receive(_ paths: [String], mustRescan: Bool) {
        guard isActive else { return }
        let relevant = paths.filter(isRelevant(path:))
        if mustRescan, relevant.isEmpty { changedPaths.insert(projectURL.path) }
        else { changedPaths.formUnion(relevant) }
        guard !changedPaths.isEmpty else { return }
        pending?.cancel()
        let refresh = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            let urls = self.changedPaths.sorted().map { URL(fileURLWithPath: $0) }
            self.changedPaths.removeAll()
            self.pending = nil
            self.onChange?(urls)
        }
        pending = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350), execute: refresh)
    }

    private nonisolated static func nearestExistingDirectory(to url: URL) -> URL {
        var candidate = url
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return url.deletingLastPathComponent() }
            candidate = parent
        }
        return candidate
    }
}
