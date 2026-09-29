import AgentRunKit
import Foundation

enum SwiftSymbolServerError: Error { case serverNotFound, unreadableFile }

/// Lazily-started `sourcekit-lsp` session for one project, exposing definition/reference lookups
/// to the agent. Swift-only in this iteration: `sourcekit-lsp` ships with the Xcode toolchain, so
/// it is zero new dependency, and there is no evidence yet of a need for another language server.
/// The type is scoped by name (`SwiftSymbolServer`, not `LSPClient`) so a future generalization is
/// a localized refactor here, not a change to the tool contract exposed to the model.
actor SwiftSymbolServer {
    private let projectRoot: URL
    private let commandRunner: ProjectCommandRunner
    private let idleTimeout: TimeInterval
    private var transport: LSPStdioTransport?
    private var openDocumentURIs: Set<String> = []
    private var diagnosticsByURI: [String: [JSONValue]] = [:]
    private var idleShutdownTask: Task<Void, Never>?
    private var cachedServerPath: URL?

    init(projectRoot: URL, commandRunner: ProjectCommandRunner, idleTimeout: TimeInterval = 600) {
        self.projectRoot = projectRoot
        self.commandRunner = commandRunner
        self.idleTimeout = idleTimeout
    }

    func findDefinition(relativePath: String, line: Int, column: Int) async -> String {
        await locate(method: "textDocument/definition", relativePath: relativePath, line: line, column: column, includeDeclaration: nil)
    }

    func findReferences(relativePath: String, line: Int, column: Int) async -> String {
        await locate(method: "textDocument/references", relativePath: relativePath, line: line, column: column, includeDeclaration: true)
    }

    /// Called by the runtime on teardown, alongside `ProjectCommandRunner.cancelAll()`.
    func shutdown() async {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        await stopTransport()
    }

    private func stopTransport() async {
        let oldTransport = transport
        transport = nil
        openDocumentURIs.removeAll()
        diagnosticsByURI.removeAll()
        await oldTransport?.shutdown()
    }

    private func locate(method: String, relativePath: String, line: Int, column: Int, includeDeclaration: Bool?) async -> String {
        guard let fileURL = resolvedFile(relativePath) else { return "Path is outside the project." }
        let transport: LSPStdioTransport
        do {
            transport = try await ensureStarted()
        } catch SwiftSymbolServerError.serverNotFound {
            return "sourcekit-lsp was not found via `xcrun --find sourcekit-lsp`. Install Xcode or its command line tools."
        } catch {
            return "sourcekit-lsp could not be started: \(error)"
        }
        defer { resetIdleTimer() }
        do {
            let uri = "file://\(fileURL.path)"
            try await openIfNeeded(transport, uri: uri, fileURL: fileURL)
            var params: [String: JSONValue] = [
                "textDocument": .object(["uri": .string(uri)]),
                "position": .object(["line": .int(line), "character": .int(column)])
            ]
            if let includeDeclaration {
                params["context"] = .object(["includeDeclaration": .bool(includeDeclaration)])
            }
            // Cold indexing can make the first request slow; give this more room than rg/ast-grep.
            let response = try await transport.sendRequest(method: method, params: .object(params), timeout: 20)
            if let error = response.error { return "sourcekit-lsp reported an error: \(error.message)" }
            return Self.formatLocations(response.result)
        } catch LSPStdioTransport.TransportError.timeout {
            return "sourcekit-lsp did not respond in time (it may still be indexing the project)."
        } catch SwiftSymbolServerError.unreadableFile {
            return "File is unavailable or not UTF-8 text."
        } catch {
            return "Code intelligence request failed: \(error)"
        }
    }

    private func ensureStarted() async throws -> LSPStdioTransport {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        if let transport { return transport }
        let binary = try await locateSourceKitLSP()
        let transport = LSPStdioTransport()
        try await transport.start(executableURL: binary, workingDirectory: projectRoot) { [weak self] notification in
            Task { await self?.handle(notification) }
        }
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        _ = try await transport.sendRequest(method: "initialize", params: .object([
            "processId": .null,
            "rootUri": .string("file://\(root.path)"),
            "capabilities": .object([:])
        ]), timeout: 20)
        try await transport.sendNotification(method: "initialized", params: .object([:]))
        self.transport = transport
        return transport
    }

    private func openIfNeeded(_ transport: LSPStdioTransport, uri: String, fileURL: URL) async throws {
        guard !openDocumentURIs.contains(uri) else { return }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { throw SwiftSymbolServerError.unreadableFile }
        try await transport.sendNotification(method: "textDocument/didOpen", params: .object([
            "textDocument": .object([
                "uri": .string(uri), "languageId": .string("swift"), "version": .int(1), "text": .string(text)
            ])
        ]))
        openDocumentURIs.insert(uri)
    }

    private func handle(_ notification: JSONRPCNotification) {
        guard notification.method == "textDocument/publishDiagnostics",
              case let .object(params)? = notification.params,
              case let .string(uri)? = params["uri"],
              case let .array(diagnostics)? = params["diagnostics"] else { return }
        // Captured for a future diagnostics tool; not exposed as a tool in this phase.
        diagnosticsByURI[uri] = diagnostics
    }

    private func resetIdleTimer() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [weak self, idleTimeout] in
            try? await Task.sleep(for: .seconds(idleTimeout))
            guard !Task.isCancelled else { return }
            await self?.stopAfterIdle()
        }
    }

    private func stopAfterIdle() async {
        idleShutdownTask = nil
        await stopTransport()
    }

    private func locateSourceKitLSP() async throws -> URL {
        if let cachedServerPath { return cachedServerPath }
        guard let result = try? await commandRunner.run(arguments: ["/usr/bin/xcrun", "--find", "sourcekit-lsp"], timeout: 5),
              result.exitCode == 0 else { throw SwiftSymbolServerError.serverNotFound }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { throw SwiftSymbolServerError.serverNotFound }
        let url = URL(fileURLWithPath: path)
        cachedServerPath = url
        return url
    }

    private func resolvedFile(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    /// Accepts both `Location` (`uri`/`range`) and `LocationLink` (`targetUri`/`targetSelectionRange`)
    /// shapes, since the exact form returned can vary by `sourcekit-lsp` version.
    private static func formatLocations(_ result: JSONValue?) -> String {
        guard let result, result != .null else { return "No results." }
        let items: [JSONValue] = { if case let .array(array) = result { return array } else { return [result] } }()
        let lines = items.compactMap(formatLocation).prefix(50)
        return lines.isEmpty ? "No results." : lines.joined(separator: "\n")
    }

    private static func formatLocation(_ value: JSONValue) -> String? {
        guard case let .object(object) = value else { return nil }
        let uriValue = object["targetUri"] ?? object["uri"]
        let rangeValue = object["targetSelectionRange"] ?? object["targetRange"] ?? object["range"]
        guard case let .string(uri)? = uriValue,
              case let .object(range)? = rangeValue,
              case let .object(start)? = range["start"],
              case let .int(line)? = start["line"],
              case let .int(column)? = start["character"] else { return nil }
        let path = uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
        return "\(path):\(line + 1):\(column + 1)"
    }
}
