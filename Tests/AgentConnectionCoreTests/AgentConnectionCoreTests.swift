import Foundation
import Testing
@testable import AgentConnectionCore

@Suite("Agent connection core", .serialized)
@MainActor
struct AgentConnectionCoreTests {
    @Test
    func testProjectsKeepProfilesSelectionRuntimeAndCredentialHomesIsolated() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectA = root.appendingPathComponent("ProjectA", isDirectory: true)
        let projectB = root.appendingPathComponent("ProjectB", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("requests.log")
        let executable = try makeManagerServer(in: root, logURL: log)
        let managerA = AgentConnectionManager(supportURL: support, metadataURL: projectA.appendingPathComponent(".fscode/connections.json"), projectRoot: projectA, runtimeFactory: CodexRuntime.live, apiKeyValidator: { _ in })
        let managerB = AgentConnectionManager(supportURL: support, metadataURL: projectB.appendingPathComponent(".fscode/connections.json"), projectRoot: projectB, runtimeFactory: CodexRuntime.live, apiKeyValidator: { _ in })

        try await managerA.load()
        try await managerB.load()
        #expect(managerA.profiles.isEmpty)
        #expect(managerB.profiles.isEmpty)
        try await managerA.configureCodexExecutable(at: executable)
        let profileA = try await managerA.createProfile(name: "Account A", kind: .chatGPT, apiKey: nil)
        #expect(managerB.profiles.isEmpty)
        #expect(managerB.selectedProfileID == nil)

        try await managerB.configureCodexExecutable(at: executable)
        let profileB = try await managerB.createProfile(name: "Account B", kind: .chatGPT, apiKey: nil)
        #expect(profileA.id != profileB.id)
        #expect(managerA.profiles == [profileA])
        #expect(managerB.profiles == [profileB])

        await managerA.connectSelected()
        await managerB.connectSelected()
        try await waitUntil { managerA.state.isConnected && managerB.state.isConnected }
        let homeA = support.appendingPathComponent("Connections/\(profileA.id.uuidString)")
        let homeB = support.appendingPathComponent("Connections/\(profileB.id.uuidString)")
        #expect(homeA != homeB)
        #expect(FileManager.default.fileExists(atPath: homeA.path))
        #expect(FileManager.default.fileExists(atPath: homeB.path))
        #expect(FileManager.default.fileExists(
            atPath: projectA.appendingPathComponent(".fscode/connections.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: projectB.appendingPathComponent(".fscode/connections.json").path
        ))

        await managerA.selectProfile(id: nil)
        #expect(managerA.state == .disconnected)
        #expect(managerB.state.isConnected)
    }

    @Test
    func testProjectConnectionStoreRejectsSymlinkedMetadataDirectory() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(".fscode"),
            withDestinationURL: outside
        )
        let manager = AgentConnectionManager(projectURL: project, applicationSupportURL: support)

        do {
            try await manager.load()
            Issue.record("Expected a symlinked connection store to fail closed")
        } catch {
            #expect(error as? AgentConnectionError == .corruptStore)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("connections.json").path))
    }

    @Test
    func testConfiguredExecutablePersists() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: "/bin/echo")
        let manager = makeManager(directory: directory)
        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        let metadataData = try Data(
            contentsOf: directory.appendingPathComponent("connections.json")
        )
        let metadata = try #require(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        #expect(metadata["executablePath"] as? String == "/bin/echo")

        let reloaded = makeManager(directory: directory)
        try await reloaded.load()
        try await reloaded.configureCodexExecutable(at: executable)
    }

    @Test
    func testProfilesPersistOnlyMetadataAndLoadIsIdempotent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeManagerServer(in: directory)
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        let profile = try await manager.createProfile(
            name: "OpenAI",
            kind: .openAIAPI,
            apiKey: "test-secret-key"
        )
        try await waitUntil { manager.state.isConnected }
        #expect(manager.state.isConnected, Comment(rawValue: manager.state.statusText))

        let metadataURL = directory.appendingPathComponent("connections.json")
        let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
        #expect(metadata.contains(profile.id.uuidString))
        #expect(!metadata.contains("test-secret-key"))
        #expect(!metadata.lowercased().contains("api_key"))

        let reloaded = makeManager(directory: directory)
        try await reloaded.load()
        try await reloaded.load()
        #expect(reloaded.profiles == [profile])
        #expect(reloaded.selectedProfileID == profile.id)
        await manager.releaseClient(UUID())
    }

    @Test
    func testOAuthCompletionUsesMatchingLoginAndPaginatesModels() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.log")
        let executable = try makeManagerServer(in: directory, logURL: log)
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        let profile = try await manager.createProfile(
            name: "ChatGPT",
            kind: .chatGPT,
            apiKey: nil
        )
        await manager.connectSelected()
        try await waitUntil { manager.state.isConnected }
        #expect(manager.state.isConnected, Comment(rawValue: manager.state.statusText))

        #expect(manager.pendingLoginURL == nil)
        #expect(manager.models.map(\.id) == ["gpt-a", "gpt-b"])
        #expect(manager.models.first?.catalogID == "catalog-a")
        #expect(manager.models.first?.supportedReasoningEfforts == ["low", "high"])
        #expect(manager.models.first?.defaultReasoningEffort == "high")
        #expect(manager.selectedProfileID == profile.id)

        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests.contains("account/login/start"))
        #expect(requests.contains("model/list|next-page"))
    }

    @Test
    func testCancelLoginSendsTheExplicitLoginID() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.log")
        let executable = try makeManagerServer(
            in: directory,
            logURL: log,
            sendLoginCompletion: false
        )
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        _ = try await manager.createProfile(name: "ChatGPT", kind: .chatGPT, apiKey: nil)
        await manager.connectSelected()
        guard case .awaitingBrowserLogin = manager.state else {
            Issue.record("Expected a pending browser login")
            return
        }

        await manager.cancelLogin()
        #expect(manager.state == .disconnected)
        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests.contains("account/login/cancel|login-123"))
    }

    @Test
    func testProfileSwitchPreventsAStaleConnectionCommit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeManagerServer(in: directory, accountReadDelay: 0.4)
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        let first = try await manager.createProfile(name: "First", kind: .chatGPT, apiKey: nil)
        let second = try await manager.createProfile(name: "Second", kind: .chatGPT, apiKey: nil)
        await manager.selectProfile(id: first.id)

        let connection = Task { await manager.connectSelected() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await manager.selectProfile(id: second.id)
        await connection.value

        #expect(manager.selectedProfileID == second.id)
        #expect(manager.state == .disconnected)
        #expect(manager.models.isEmpty)
    }

    @Test
    func testAccountKindMismatchNeverAppearsConnected() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeManagerServer(in: directory, initialAccountKind: "apiKey")
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        _ = try await manager.createProfile(name: "ChatGPT", kind: .chatGPT, apiKey: nil)
        await manager.connectSelected()

        guard case .failed = manager.state else {
            Issue.record("A mismatched account must fail closed")
            return
        }
        #expect(manager.models.isEmpty)
    }

    @Test
    func testRemovingInactiveProfileLogsOutItsIsolatedHome() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.log")
        let executable = try makeManagerServer(in: directory, logURL: log)
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        let inactive = try await manager.createProfile(name: "Inactive", kind: .chatGPT, apiKey: nil)
        let selected = try await manager.createProfile(name: "Selected", kind: .chatGPT, apiKey: nil)

        try await manager.removeProfile(id: inactive.id)

        #expect(manager.profiles == [selected])
        #expect(manager.selectedProfileID == selected.id)
        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests.contains("account/logout"))
        #expect(requests.contains(inactive.id.uuidString))
    }

    @Test
    func testFailedLogoutRetainsProfile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeManagerServer(in: directory, logoutFails: true)
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        let profile = try await manager.createProfile(name: "Keep me", kind: .chatGPT, apiKey: nil)

        do {
            try await manager.removeProfile(id: profile.id)
            Issue.record("Expected logout failure")
        } catch {
            #expect(manager.profiles == [profile])
            #expect(manager.selectedProfileID == profile.id)
        }
    }

    @Test
    func testCorruptStoreFailsClosedAndCanBeRetried() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let duplicateID = UUID()
        let corrupt = """
        {"version":1,"profiles":[
          {"id":"\(duplicateID)","name":"A","kind":"chatGPT"},
          {"id":"\(duplicateID)","name":"B","kind":"chatGPT"}
        ]}
        """
        try Data(corrupt.utf8).write(to: directory.appendingPathComponent("connections.json"))
        let manager = makeManager(directory: directory)

        do {
            try await manager.load()
            Issue.record("Expected corrupt store error")
        } catch {
            #expect(error as? AgentConnectionError == .corruptStore)
            #expect(manager.profiles.isEmpty)
        }

        let originalData = try Data(contentsOf: directory.appendingPathComponent("connections.json"))
        do {
            _ = try await manager.createProfile(name: "Must not overwrite", kind: .chatGPT, apiKey: nil)
            Issue.record("Expected corrupt store error")
        } catch {
            #expect(error as? AgentConnectionError == .corruptStore)
        }
        do {
            try await manager.configureCodexExecutable(at: URL(fileURLWithPath: "/bin/echo"))
            Issue.record("Expected corrupt store error")
        } catch {
            #expect(error as? AgentConnectionError == .corruptStore)
        }
        #expect(
            try Data(contentsOf: directory.appendingPathComponent("connections.json"))
                == originalData
        )

        try Data("{\"version\":1,\"profiles\":[]}".utf8)
            .write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try await manager.load()
        #expect(manager.state == .disconnected)
        #expect(manager.profiles.isEmpty)
    }

    @Test
    func testFailedMetadataWriteRollsBackRename() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = makeManager(directory: directory)
        try await manager.load()
        let profile = try await manager.createProfile(name: "Original", kind: .chatGPT, apiKey: nil)

        let metadata = directory.appendingPathComponent("connections.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)

        do {
            try await manager.renameProfile(id: profile.id, name: "Changed")
            Issue.record("Expected persistence failure")
        } catch {
            #expect(manager.profiles.first?.name == "Original")
        }
    }

    @Test
    func testRuntimeHandlesPartialFramesCancellationTimeoutAndEOF() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeTransportServer(in: directory)
        var runtimeNumber = 0
        func makeRuntime() -> CodexRuntime {
            runtimeNumber += 1
            return CodexRuntime(
                executable: executable,
                home: directory.appendingPathComponent("runtime-\(runtimeNumber)"),
                requestTimeout: 0.5
            )
        }

        let frameRuntime = makeRuntime()
        let notification = LockedFlag()
        frameRuntime.onNotification = { value in
            if value.method == "test/note", value.params["value"] as? Int == 7 {
                notification.value = true
            }
        }
        try frameRuntime.start()

        let result = try await frameRuntime.request(method: "partial", params: [:]).object
        #expect(result["ok"] as? Bool == true)
        try await waitUntil { notification.value }
        let collision = try await frameRuntime.request(method: "serverRequest", params: [:]).object
        #expect(collision["ok"] as? Bool == true)

        frameRuntime.onDynamicToolCall = { call in
            guard call.requestID == .string("dynamic-string"),
                  call.threadID == "thread-1",
                  call.turnID == "turn-1",
                  call.callID == "call-1",
                  call.toolName == "fs_edit_file",
                  call.arguments == .object(["path": .string("File.swift")]) else {
                return .rejected("invalid request")
            }
            return .accepted("staged")
        }
        let dynamicString = try await frameRuntime.request(method: "dynamicString", params: [:]).object
        #expect(dynamicString["ok"] as? Bool == true)

        frameRuntime.onDynamicToolCall = { call in
            guard call.requestID == .integer(0),
                  call.arguments == .object([
                    "zero": .integer(0),
                    "one": .integer(1),
                    "flag": .bool(true)
                  ]) else {
                return .rejected("invalid zero request id or JSON scalar types")
            }
            return .accepted("staged")
        }
        let dynamicZero = try await frameRuntime.request(method: "dynamicZero", params: [:]).object
        #expect(dynamicZero["ok"] as? Bool == true)

        frameRuntime.onDynamicToolCall = { call in
            guard call.requestID == .integer(1) else {
                return .rejected("invalid one request id")
            }
            return .accepted("staged")
        }
        let dynamicOne = try await frameRuntime.request(method: "dynamicOne", params: [:]).object
        #expect(dynamicOne["ok"] as? Bool == true)

        let dynamicBoolean = try await frameRuntime.request(method: "dynamicBoolean", params: [:]).object
        #expect(dynamicBoolean["rejected"] as? Bool == true)

        frameRuntime.onDynamicToolCall = { call in
            guard call.requestID == .integer(9_000_000_000) else {
                return .rejected("invalid request id")
            }
            return .accepted("staged")
        }
        let dynamicInteger = try await frameRuntime.request(method: "dynamicInteger", params: [:]).object
        #expect(dynamicInteger["ok"] as? Bool == true)
        frameRuntime.stop()

        let staleRuntime = makeRuntime()
        let dynamicCallCancelled = LockedFlag()
        staleRuntime.onDynamicToolCall = { _ in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                dynamicCallCancelled.value = true
            }
            return .accepted("must not be sent")
        }
        try staleRuntime.start()
        let staleRequest = Task {
            try await staleRuntime.request(method: "dynamicDelayed", params: [:])
        }
        try await Task.sleep(for: .milliseconds(50))
        staleRuntime.cancelDynamicToolCalls()
        let cancelledResponse = try await staleRequest.value.object
        #expect(cancelledResponse["cancelled"] as? Bool == true)
        try await waitUntil { dynamicCallCancelled.value }
        staleRuntime.stop()

        let timeoutRuntime = makeRuntime()
        try timeoutRuntime.start()
        do {
            _ = try await timeoutRuntime.request(method: "timeout", params: [:])
            Issue.record("Expected timeout")
        } catch {
            #expect(error as? CodexRuntime.RuntimeError == .timedOut)
        }

        let cancellationRuntime = makeRuntime()
        try cancellationRuntime.start()
        let task = Task {
            try await cancellationRuntime.request(method: "timeout", params: [:])
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        let eofRuntime = makeRuntime()
        let terminated = LockedFlag()
        eofRuntime.onTermination = { error in
            if error == .terminated { terminated.value = true }
        }
        try eofRuntime.start()
        do {
            _ = try await eofRuntime.request(method: "eof", params: [:])
            Issue.record("Expected termination")
        } catch {
            #expect(error as? CodexRuntime.RuntimeError == .terminated)
        }
        try await waitUntil { terminated.value }
        eofRuntime.stop()
    }

    @Test
    func testUnexpectedRuntimeExitInvalidatesConnectedSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeManagerServer(in: directory)
        let manager = makeManager(directory: directory)

        try await manager.load()
        try await manager.configureCodexExecutable(at: executable)
        let profile = try await manager.createProfile(
            name: "OpenAI",
            kind: .openAIAPI,
            apiKey: "test-secret-key"
        )
        try await waitUntil { manager.state.isConnected }
        _ = try await manager.requestSelectedRuntime(
            method: "exitSoon",
            params: [:],
            expectedProfileID: profile.id
        )
        try await waitUntil {
            if case .failed = manager.state { return true }
            return false
        }
        #expect(manager.models.isEmpty)
    }

    @Test
    func testNamesAndModelSelectionAreValidated() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = makeManager(directory: directory)
        try await manager.load()

        do {
            _ = try await manager.createProfile(name: "  ", kind: .chatGPT, apiKey: nil)
            Issue.record("Expected invalid name")
        } catch {
            #expect(error as? AgentConnectionError == .invalidName)
        }
        _ = try await manager.createProfile(name: "A", kind: .chatGPT, apiKey: nil)
        do {
            try await manager.selectModel(id: "invented")
            Issue.record("Expected unavailable model")
        } catch {
            #expect(error is AgentConnectionError)
        }
    }

    private func makeManager(directory: URL) -> AgentConnectionManager {
        AgentConnectionManager(
            applicationSupportURL: directory,
            runtimeFactory: CodexRuntime.live,
            apiKeyValidator: { _ in }
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                Issue.record("Timed out waiting for state")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeManagerServer(
        in directory: URL,
        logURL: URL? = nil,
        sendLoginCompletion: Bool = true,
        accountReadDelay: Double = 0,
        initialAccountKind: String? = nil,
        logoutFails: Bool = false
    ) throws -> URL {
        let logPath = logURL?.path ?? directory.appendingPathComponent("unused.log").path
        let initialKind = initialAccountKind.map { "'\($0)'" } ?? "None"
        let source = """
        #!/usr/bin/env python3
        import json, os, sys, time
        log_path = \(pythonLiteral(logPath))
        account_kind = \(initialKind)
        reads = 0
        def send(value):
            time.sleep(0.01)
            sys.stdout.write(json.dumps(value, separators=(',', ':')) + '\\n')
            sys.stdout.flush()
        def log(method, obj):
            cursor = obj.get('params', {}).get('cursor', '')
            login_id = obj.get('params', {}).get('loginId', '')
            with open(log_path, 'a') as handle:
                handle.write(method + '|' + str(cursor or login_id) + '|' + os.environ.get('CODEX_HOME', '') + '\\n')
        for line in sys.stdin:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            method = obj.get('method', '')
            log(method, obj)
            if 'id' not in obj:
                continue
            request_id = obj['id']
            if method == 'initialize':
                send({'id': request_id, 'result': {'serverInfo': {'name': 'fake'}}})
            elif method == 'account/read':
                if \(accountReadDelay) > 0:
                    time.sleep(\(accountReadDelay))
                reads += 1
                if account_kind == 'chatgpt':
                    account = {'type': 'chatgpt', 'email': 'person@example.com'}
                elif account_kind == 'apiKey':
                    account = {'type': 'apiKey'}
                else:
                    account = None
                send({'id': request_id, 'result': {'account': account, 'requiresOpenaiAuth': account is None}})
            elif method == 'account/login/start':
                login_type = obj.get('params', {}).get('type')
                if login_type == 'apiKey':
                    account_kind = 'apiKey'
                    send({'id': request_id, 'result': {'type': 'apiKey'}})
                else:
                    if \(sendLoginCompletion ? "True" : "False"):
                        account_kind = 'chatgpt'
                        response = {'id': request_id, 'result': {'type': 'chatgpt', 'loginId': 'login-123', 'authUrl': 'https://auth.example.test/'}}
                        completed = {'method': 'account/login/completed', 'params': {'loginId': 'login-123', 'success': True}}
                        sys.stdout.write(json.dumps(response, separators=(',', ':')) + '\\n' + json.dumps(completed, separators=(',', ':')) + '\\n')
                        sys.stdout.flush()
                    else:
                        send({'id': request_id, 'result': {'type': 'chatgpt', 'loginId': 'login-123', 'authUrl': 'https://auth.example.test/'}})
            elif method == 'account/login/cancel':
                send({'id': request_id, 'result': {}})
            elif method == 'account/logout':
                if \(logoutFails ? "True" : "False"):
                    send({'id': request_id, 'error': {'code': -32000, 'message': 'failed'}})
                else:
                    account_kind = None
                    send({'id': request_id, 'result': {}})
            elif method == 'model/list':
                if obj.get('params', {}).get('cursor') == 'next-page':
                    data = [{'id': 'catalog-b', 'model': 'gpt-b', 'displayName': 'Zulu', 'hidden': False, 'isDefault': False, 'supportedReasoningEfforts': [], 'defaultReasoningEffort': 'medium'}]
                    send({'id': request_id, 'result': {'data': data, 'nextCursor': None}})
                else:
                    efforts = [{'reasoningEffort': 'low', 'description': 'Low'}, {'reasoningEffort': 'high', 'description': 'High'}]
                    data = [{'id': 'catalog-a', 'model': 'gpt-a', 'displayName': 'Alpha', 'hidden': False, 'isDefault': True, 'supportedReasoningEfforts': efforts, 'defaultReasoningEffort': 'high'}]
                    send({'id': request_id, 'result': {'data': data, 'nextCursor': 'next-page'}})
            elif method == 'exitSoon':
                send({'id': request_id, 'result': {'accepted': True}})
                time.sleep(0.05)
                sys.exit(0)
            else:
                send({'id': request_id, 'result': {}})
        """
        return try writeExecutable(source, in: directory, name: "fake-manager-server.py")
    }

    private func makeTransportServer(in directory: URL) throws -> URL {
        let source = """
        #!/usr/bin/env python3
        import json, sys, time
        for line in sys.stdin:
            obj = json.loads(line)
            method = obj.get('method')
            request_id = obj.get('id')
            if method == 'partial':
                note = json.dumps({'method': 'test/note', 'params': {'value': 7}}, separators=(',', ':'))
                response = json.dumps({'id': request_id, 'result': {'ok': True}}, separators=(',', ':'))
                payload = (note + '\\n' + response + '\\n').encode()
                sys.stdout.buffer.write(payload[:9])
                sys.stdout.buffer.flush()
                time.sleep(0.03)
                sys.stdout.buffer.write(payload[9:])
                sys.stdout.buffer.flush()
            elif method == 'timeout':
                continue
            elif method == 'serverRequest':
                print(json.dumps({'id': request_id, 'method': 'unknown/serverCall', 'params': {}}), flush=True)
                reply = json.loads(sys.stdin.readline())
                if reply.get('id') == request_id and reply.get('error', {}).get('code') == -32601:
                    print(json.dumps({'id': request_id, 'result': {'ok': True}}), flush=True)
            elif method in ('dynamicString', 'dynamicZero', 'dynamicOne', 'dynamicInteger', 'dynamicDelayed'):
                ids = {
                    'dynamicString': 'dynamic-string',
                    'dynamicZero': 0,
                    'dynamicOne': 1,
                    'dynamicInteger': 9000000000,
                    'dynamicDelayed': 'dynamic-string'
                }
                server_id = ids[method]
                arguments = {'zero': 0, 'one': 1, 'flag': True} if method == 'dynamicZero' else {'path': 'File.swift'}
                call = {
                    'id': server_id,
                    'method': 'item/tool/call',
                    'params': {
                        'threadId': 'thread-1',
                        'turnId': 'turn-1',
                        'callId': 'call-1',
                        'tool': 'fs_edit_file',
                        'arguments': arguments
                    }
                }
                print(json.dumps(call), flush=True)
                reply = json.loads(sys.stdin.readline())
                result = reply.get('result', {})
                items = result.get('contentItems', [])
                expected_success = method != 'dynamicDelayed'
                valid = reply.get('id') == server_id and result.get('success') is expected_success and items and items[0].get('type') == 'inputText'
                response = {'cancelled': valid} if method == 'dynamicDelayed' else {'ok': valid}
                print(json.dumps({'id': request_id, 'result': response}), flush=True)
            elif method == 'dynamicBoolean':
                print(json.dumps({
                    'id': True,
                    'method': 'item/tool/call',
                    'params': {
                        'threadId': 'thread-1',
                        'turnId': 'turn-1',
                        'callId': 'call-1',
                        'tool': 'fs_edit_file',
                        'arguments': {}
                    }
                }), flush=True)
                reply = json.loads(sys.stdin.readline())
                valid = reply.get('id') is True and reply.get('error', {}).get('code') == -32602
                print(json.dumps({'id': request_id, 'result': {'rejected': valid}}), flush=True)
            elif method == 'eof':
                sys.exit(0)
            else:
                print(json.dumps({'id': request_id, 'result': {}}), flush=True)
        """
        return try writeExecutable(source, in: directory, name: "fake-transport-server.py")
    }

    private func writeExecutable(_ source: String, in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func pythonLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
    }
}

private extension AgentConnectionState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
