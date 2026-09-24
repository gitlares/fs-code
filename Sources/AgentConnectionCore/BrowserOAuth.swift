import CryptoKit
import Darwin
import Foundation
import Security

public enum BrowserAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case portBusy
    case denied
    case cancelled
    case malformedCallback

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Browser authorization is unavailable."
        case .portBusy: "Browser authorization cannot start because its local callback port is in use."
        case .denied: "Browser authorization was denied."
        case .cancelled: "Browser authorization was cancelled."
        case .malformedCallback: "Browser authorization could not be completed."
        }
    }
}

/// A single browser authorization attempt. The listener is started before its
/// URL is returned, preventing a redirect from racing the local callback server.
public final class BrowserAuthorizationSession: @unchecked Sendable {
    public let authorizationURL: URL

    let codeVerifier: String
    private let listener: LoopbackCallbackListener

    init(authorizationURL: URL, codeVerifier: String, listener: LoopbackCallbackListener) {
        self.authorizationURL = authorizationURL
        self.codeVerifier = codeVerifier
        self.listener = listener
    }

    public func waitForCode() async throws -> String {
        try await listener.waitForCode()
    }

    public func cancel() {
        listener.cancel()
    }

    deinit {
        cancel()
    }
}

enum BrowserOAuth {
    static let redirectURI = "http://localhost:1455/auth/callback"

    static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BrowserAuthorizationError.unavailable
        }
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A small, purpose-built HTTP listener. It only binds the IPv4 loopback
/// address and accepts one request, so it is never reachable from the network.
final class LoopbackCallbackListener: @unchecked Sendable {
    private static let maximumRequestSize = 16 * 1024
    private static let receiveTimeoutSeconds: Int = 15
    private static let authorizationTimeout: TimeInterval = 10 * 60

    private let expectedState: String
    private let lock = NSLock()
    private var listeningSocket: Int32 = -1
    private var activeClientSocket: Int32 = -1
    private var completion: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(expectedState: String, port: UInt16 = 1455) throws {
        self.expectedState = expectedState
        listeningSocket = try Self.openListeningSocket(port: port)
        DispatchQueue.global(qos: .utility).async { [self] in
            receiveCallbacks()
        }
    }

    deinit {
        cancel()
    }

    func waitForCode() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else if completion != nil {
                    lock.unlock()
                    continuation.resume(throwing: BrowserAuthorizationError.unavailable)
                } else {
                    completion = continuation
                    lock.unlock()
                }
            }
        }, onCancel: {
            self.cancel()
        })
    }

    func cancel() {
        finish(.failure(BrowserAuthorizationError.cancelled))
    }

    private func currentListeningSocket() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return result == nil ? listeningSocket : -1
    }

    private func activate(_ client: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return false }
        activeClientSocket = client
        return true
    }

    private func clearActiveClient(_ client: Int32) {
        lock.lock()
        if activeClientSocket == client { activeClientSocket = -1 }
        lock.unlock()
    }

    private func receiveCallbacks() {
        defer { closeListeningSocketFromWorker() }
        let deadline = Date().addingTimeInterval(Self.authorizationTimeout)
        while Date() < deadline {
            let fd = currentListeningSocket()
            guard fd >= 0 else { return }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, 1_000)
            if pollResult == 0 { continue }
            if pollResult < 0 { continue }

            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &address, &length)
            guard client >= 0 else { continue }
            guard activate(client) else {
                close(client)
                return
            }

            var timeout = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) {
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) {
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }

            let outcome = Self.parseRequest(from: client, expectedState: expectedState)
            switch outcome {
            case let .success(code):
                Self.respond(on: client, status: 200, body: "Code received. You can return to FS Code.")
                clearActiveClient(client)
                close(client)
                finish(.success(code))
                return
            case let .failure(error):
                Self.respond(on: client, status: 400, body: "Authorization could not be completed. You can close this window.")
                clearActiveClient(client)
                close(client)
                if error as? BrowserAuthorizationError == .denied {
                    finish(.failure(BrowserAuthorizationError.denied))
                    return
                }
            }
        }
        finish(.failure(BrowserAuthorizationError.unavailable))
    }

    private func finish(_ newResult: Result<String, Error>) {
        let continuation: CheckedContinuation<String, Error>?
        let socket: Int32
        let client: Int32
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        continuation = completion
        completion = nil
        socket = listeningSocket
        client = activeClientSocket
        activeClientSocket = -1
        // Coordinate shutdown with the worker's close so a reused descriptor
        // can never be touched after the lock is released.
        if client >= 0 { shutdown(client, SHUT_RDWR) }
        if socket >= 0 { shutdown(socket, SHUT_RDWR) }
        lock.unlock()
        continuation?.resume(with: newResult)
    }

    private func closeListeningSocketFromWorker() {
        let socket: Int32
        lock.lock()
        socket = listeningSocket
        listeningSocket = -1
        lock.unlock()
        if socket >= 0 { close(socket) }
    }

    private static func openListeningSocket(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserAuthorizationError.unavailable }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw BrowserAuthorizationError.portBusy
        }
        return fd
    }

    private static func parseRequest(from fd: Int32, expectedState: String) -> Result<String, Error> {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < maximumRequestSize {
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { return .failure(BrowserAuthorizationError.malformedCallback) }
            data.append(contentsOf: buffer.prefix(received))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil,
              let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first else {
            return .failure(BrowserAuthorizationError.malformedCallback)
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost\(parts[1])"),
              components.path == "/auth/callback" else {
            return .failure(BrowserAuthorizationError.malformedCallback)
        }
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        guard state == expectedState else { return .failure(BrowserAuthorizationError.malformedCallback) }
        if components.queryItems?.contains(where: { $0.name == "error" && !($0.value ?? "").isEmpty }) == true {
            return .failure(BrowserAuthorizationError.denied)
        }
        guard let code, !code.isEmpty else { return .failure(BrowserAuthorizationError.malformedCallback) }
        return .success(code)
    }

    private static func respond(on fd: Int32, status: Int, body: String) {
        let content = "<html><body><p>\(body)</p></body></html>"
        let reason = status == 200 ? "OK" : "Bad Request"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(content.utf8.count)\r\nConnection: close\r\n\r\n\(content)"
        _ = response.withCString { send(fd, $0, strlen($0), 0) }
    }
}
