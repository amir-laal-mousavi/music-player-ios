import Foundation
import MusicCore
import XCTest
@testable import TelegramClient

final class TelegramGatewayTests: XCTestCase {
    private let testDatabaseEncryptionKey = Data(repeating: 0x5A, count: 32)
    private var root: URL!
    private var workspace: URL!
    private var downloadDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TelegramGatewayTests-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        downloadDirectory = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testPhoneCodePasswordLoginAndMaskedAccount() async throws {
        let (gateway, transport) = try makeWaitingGateway()
        defer { transport.setHandler { _ in } }
        try await gateway.submitPhone(SyntheticFixtures.phoneNumber)
        try await waitForAuth(.waitingForCode, from: gateway)
        try await gateway.submitCode(String(repeating: "1", count: 6))
        try await waitForAuth(.waitingForPassword, from: gateway)
        try await gateway.submitPassword(SyntheticFixtures.password)
        try await waitForAuth(.authenticated, from: gateway)
        let account = try XCTUnwrap(await gateway.currentAccount)
        XCTAssertEqual(account.maskedPhoneNumber, String(repeating: "•", count: 8) + String(repeating: "0", count: 4))
        let state = await gateway.authState
        XCTAssertEqual(state, .authenticated)
        let requests = transport.sentRecords().map(\.type)
        XCTAssertTrue(requests.contains("setAuthenticationPhoneNumber"))
        XCTAssertTrue(requests.contains("checkAuthenticationCode"))
        XCTAssertTrue(requests.contains("checkAuthenticationPassword"))
        let phoneRequest = try XCTUnwrap(transport.sentRecords().first {
            $0.type == "setAuthenticationPhoneNumber"
        })
        XCTAssertTrue(phoneRequest.object["settings"] is NSNull)
    }

    func testProtocolObserverReceivesCurrentState() async throws {
        let (gateway, _) = try makeWaitingGateway()
        try await waitForAuth(.waitingForPhone, from: gateway)
        let api: TelegramGateway = gateway
        var iterator = api.observeAuthState().makeAsyncIterator()
        let state = await iterator.next()
        XCTAssertEqual(state, .waitingForPhone)
    }

    func testWaitForParametersSendsOnlyPinnedSchemaFields() async throws {
        let transport = TestTransport()
        transport.setHandler { [weak transport] record in
            guard record.type == "setTdlibParameters" else { return }
            transport?.respondOK(to: record)
            try? transport?.emit(SyntheticFixtures.authUpdate("authorizationStateWaitPhoneNumber"))
        }
        let gateway = try TelegramGatewayClient(
            apiID: 12345,
            apiHash: SyntheticFixtures.apiHash,
            downloadDirectory: downloadDirectory,
            transport: transport,
            workspaceDirectory: workspace,
            databaseEncryptionKey: testDatabaseEncryptionKey
        )
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateWaitTdlibParameters"))
        let request = try await transport.nextRequest(ofType: "setTdlibParameters")
        let object = request.object
        XCTAssertEqual(object["api_id"] as? Int, 12345)
        XCTAssertEqual(object["api_hash"] as? String, SyntheticFixtures.apiHash)
        XCTAssertEqual(object["database_directory"] as? String, workspace.resolvingSymlinksInPath().appendingPathComponent("database").path)
        XCTAssertEqual(object["files_directory"] as? String, workspace.resolvingSymlinksInPath().appendingPathComponent("files").path)
        XCTAssertEqual(object["use_test_dc"] as? Bool, false)
        XCTAssertEqual(object["use_secret_chats"] as? Bool, false)
        XCTAssertNil(object["ignore_file_names"])
        XCTAssertNil(object["enable_storage_optimizer"])
        let key = try XCTUnwrap(object["database_encryption_key"] as? String)
        XCTAssertEqual(key, testDatabaseEncryptionKey.base64EncodedString())
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: key)).count, 32)
        try await waitForAuth(.waitingForPhone, from: gateway)
    }

    func testDefaultWorkspaceUsesStableApplicationSupportPath() throws {
        let first = try TelegramGatewayClient.defaultWorkspaceDirectory()
        let second = try TelegramGatewayClient.defaultWorkspaceDirectory()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "TelegramClient")
        let applicationSupport = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first)
        XCTAssertEqual(first.deletingLastPathComponent(), applicationSupport)
    }

    func testPersistentWorkspaceConfigurationReusesSelectedPathAndStoredKey() throws {
        var storedKeys: [URL: Data] = [:]
        func loadOrCreateKey(_ workspace: URL) throws -> Data {
            if let key = storedKeys[workspace] { return key }
            let key = testDatabaseEncryptionKey
            storedKeys[workspace] = key
            return key
        }
        let first = try TelegramGatewayClient.persistentWorkspaceConfiguration(
            workspaceDirectory: workspace,
            loadOrCreateKey: loadOrCreateKey
        )
        let second = try TelegramGatewayClient.persistentWorkspaceConfiguration(
            workspaceDirectory: workspace,
            loadOrCreateKey: loadOrCreateKey
        )
        XCTAssertEqual(first.workspace, second.workspace)
        XCTAssertEqual(first.workspace, workspace.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(first.encryptionKey, second.encryptionKey)
        XCTAssertEqual(storedKeys.count, 1)
    }

    func testChatsAndBackwardAudioHistory() async throws {
        let chatID = -Int64(String(repeating: "1", count: 6))!
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            switch record.type {
            case "getChats":
                transport?.respond(["@type": "chats", "total_count": 1, "chat_ids": [String(chatID)]], to: record)
            case "getChat":
                transport?.respond(
                    SyntheticFixtures.chat(
                        id: chatID,
                        title: "Synthetic channel",
                        type: ["@type": "chatTypeSupergroup", "supergroup_id": 1, "is_channel": true]
                    ),
                    to: record
                )
            case "getChatHistory":
                let before = record.object["from_message_id"] as? Int ?? 0
                let messages: [Any] = before == 0
                    ? [SyntheticFixtures.audioMessage(id: 20, chatID: chatID), SyntheticFixtures.audioMessage(id: 10, chatID: chatID)]
                    : [SyntheticFixtures.audioMessage(id: 5, chatID: chatID)]
                transport?.respond(["@type": "messages", "messages": messages], to: record)
            default:
                break
            }
        }
        let chats = try await gateway.loadChats()
        XCTAssertEqual(chats, [try TelegramChat(id: chatID, title: "Synthetic channel", kind: .channel)])
        let firstRequest = try TelegramAudioPageRequest(chatID: chatID, beforeMessageID: nil, limit: 2)
        let first = try await gateway.loadAudioMessages(firstRequest)
        XCTAssertEqual(first.messages.map(\.messageID), [20, 10])
        let secondRequest = try TelegramAudioPageRequest(chatID: chatID, beforeMessageID: first.nextCursor, limit: 2)
        let second = try await gateway.loadAudioMessages(secondRequest)
        XCTAssertEqual(second.messages.map(\.messageID), [5])
        let chatsRequest = try XCTUnwrap(transport.sentRecords().first { $0.type == "getChats" })
        XCTAssertEqual((chatsRequest.object["chat_list"] as? [String: Any])?["@type"] as? String, "chatListMain")
        XCTAssertEqual(chatsRequest.object["limit"] as? Int, 100)
        let historyRequests = transport.sentRecords().filter { $0.type == "getChatHistory" }
        XCTAssertEqual(historyRequests.count, 2)
        XCTAssertEqual(historyRequests[0].object["offset"] as? String, "0")
        XCTAssertEqual(historyRequests[0].object["only_local"] as? Bool, false)
        XCTAssertEqual(historyRequests[1].object["from_message_id"] as? Int, 10)
    }

    func testHistorySkipsNonAudioBatchesWithoutLosingOlderAudio() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "getChatHistory" else { return }
            let before = record.object["from_message_id"] as? Int ?? 0
            let messages: [Any] = before == 0
                ? [SyntheticFixtures.textMessage(id: 20, chatID: 1)]
                : (before == 20 ? [SyntheticFixtures.audioMessage(id: 10, chatID: 1)] : [])
            transport?.respond(["@type": "messages", "messages": messages], to: record)
        }
        let request = try TelegramAudioPageRequest(chatID: 1, beforeMessageID: nil, limit: 2)
        let page = try await gateway.loadAudioMessages(request)
        XCTAssertEqual(page.messages.map(\.messageID), [10])
        XCTAssertEqual(transport.sentRecords().filter { $0.type == "getChatHistory" }.count, 3)
    }

    func testRateLimitDoesNotPoisonWaitingAuthenticationState() async throws {
        let transport = TestTransport()
        transport.setHandler { [weak transport] record in
            if record.type == "setAuthenticationPhoneNumber" { transport?.respondError(code: 429, to: record) }
        }
        let gateway = try TelegramGatewayClient(
            apiID: 12345,
            apiHash: SyntheticFixtures.apiHash,
            downloadDirectory: downloadDirectory,
            transport: transport,
            workspaceDirectory: workspace,
            databaseEncryptionKey: testDatabaseEncryptionKey
        )
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateWaitPhoneNumber"))
        try await waitForAuth(.waitingForPhone, from: gateway)
        await assertDomainError(.telegram(.rateLimited)) {
            try await gateway.submitPhone(SyntheticFixtures.phoneNumber)
        }
        let state = await gateway.authState
        XCTAssertEqual(state, .waitingForPhone)
    }

    func testMissingChatMapsToExistingDomainError() async throws {
        let (gateway, _) = try await makeAuthenticatedGateway { [weak transport] record in
            if record.type == "getChatHistory" { transport?.respondError(code: 404, to: record) }
        }
        let request = try TelegramAudioPageRequest(chatID: 1, beforeMessageID: nil, limit: 10)
        await assertDomainError(.chatNotFound(1)) {
            try await gateway.loadAudioMessages(request)
        }
    }

    func testLogoutClearsAccountAndEndsUnauthenticated() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "logOut" else { return }
            transport?.respondOK(to: record)
            try? transport?.emit(SyntheticFixtures.authUpdate("authorizationStateClosed"))
        }
        try await gateway.logout()
        try await waitForAuth(.unauthenticated, from: gateway)
        let clearedAccount = await gateway.currentAccount
        XCTAssertNil(clearedAccount)
        await assertDomainError(.unauthenticated) {
            try await gateway.loadChats()
        }
    }

    func testMalformedAccountFailsAuthenticationWithoutLeakingData() async throws {
        let (gateway, _) = try makeWaitingGateway(
            user: ["@type": "user", "id": "not-an-integer"]
        )
        try await gateway.submitPhone(SyntheticFixtures.phoneNumber)
        try await waitForAuth(.waitingForCode, from: gateway)
        try await gateway.submitCode(String(repeating: "1", count: 6))
        try await waitForAuth(.waitingForPassword, from: gateway)
        try await gateway.submitPassword(SyntheticFixtures.password)
        try await withTimeout {
            let stream = gateway.observeAuthState()
            for await state in stream {
                if case let .failure(error) = state {
                    XCTAssertEqual(error, .telegram(.invalidResponse))
                    return
                }
            }
            throw TestFailure.timedOut
        }
        let clearedAccount = await gateway.currentAccount
        XCTAssertNil(clearedAccount)
    }

    func testDownloadPublishesContainedFileAndReportsActualProgress() async throws {
        let payload = Data("synthetic completed audio".utf8)
        let filesDirectory = workspace.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let source = filesDirectory.appendingPathComponent("tdlib-cache")
        try payload.write(to: source)
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            transport?.respond(
                SyntheticFixtures.file(size: Int64(payload.count), path: source.path, completed: true, downloaded: Int64(payload.count)),
                to: record
            )
        }
        let audio = try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: 1, messageID: 7),
            fileID: 91,
            fileReference: "synthetic-file-reference",
            title: "../../must-not-be-used",
            performer: "Synthetic performer",
            duration: 42,
            fileSize: Int64(payload.count),
            mimeType: "audio/mpeg"
        )
        let recorder = ProgressRecorder()
        let destination = try await gateway.downloadAudio(audio) { recorder.record($0) }
        let approvedDirectory = downloadDirectory.resolvingSymlinksInPath().standardizedFileURL
        let downloadState = await gateway.authState
        XCTAssertEqual(downloadState, .authenticated)
        XCTAssertEqual(destination.deletingLastPathComponent(), approvedDirectory)
        XCTAssertTrue(destination.lastPathComponent.hasSuffix(".mp3"))
        XCTAssertFalse(destination.lastPathComponent.contains("must-not"))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(recorder.snapshot().last, DownloadProgress(totalBytes: Int64(payload.count), completedBytes: Int64(payload.count)))
        let downloadRequest = try XCTUnwrap(transport.sentRecords().first { $0.type == "downloadFile" })
        XCTAssertEqual(downloadRequest.object["offset"] as? Int, 0)
        XCTAssertEqual(downloadRequest.object["limit"] as? Int, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloadDirectory.resolvingSymlinksInPath().path).count, 1)
        XCTAssertFalse(transport.sentRecords().contains { $0.type == "deleteFile" })
    }

    func testDownloadRejectsSourceOutsideTDLibDirectory() async throws {
        let outside = workspace.appendingPathComponent("outside-cache")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        let (gateway, _) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            transport?.respond(SyntheticFixtures.file(size: 7, path: outside.path, completed: true, downloaded: 7), to: record)
        }
        let audio = try syntheticAudio(size: 7)
        await assertDomainError(.telegram(.downloadFailed)) {
            _ = try await gateway.downloadAudio(audio) { _ in }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloadDirectory.resolvingSymlinksInPath().path).isEmpty)
    }

    func testDownloadSizeMismatchCleansPartialFiles() async throws {
        let filesDirectory = workspace.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let source = filesDirectory.appendingPathComponent("tdlib-cache")
        try Data("bad".utf8).write(to: source)
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            transport?.respond(SyntheticFixtures.file(size: 12, path: source.path, completed: true, downloaded: 3), to: record)
        }
        await assertDomainError(.telegram(.downloadFailed)) {
            _ = try await gateway.downloadAudio(try syntheticAudio(size: 12)) { _ in }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloadDirectory.resolvingSymlinksInPath().path).isEmpty)
        XCTAssertTrue(transport.sentRecords().contains { $0.type == "deleteFile" })
    }

    func testDownloadCancellationCleansPartialFilesAndTDLibCache() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            transport?.respond(SyntheticFixtures.file(size: 12, path: "", completed: false, downloaded: 0), to: record)
        }
        let recorder = ProgressRecorder()
        let audio = try syntheticAudio(size: 12)
        let task = Task {
            try await gateway.downloadAudio(audio) { recorder.record($0) }
        }
        _ = try await withTimeout {
            for await _ in recorder.updates { return }
            throw TestFailure.timedOut
        }
        await gateway.cancelDownload(for: audio.identity)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloadDirectory.resolvingSymlinksInPath().path).isEmpty)
        let requests = transport.sentRecords()
        XCTAssertTrue(requests.contains { $0.type == "cancelDownloadFile" })
        XCTAssertTrue(requests.contains { $0.type == "deleteFile" })
        let cancelRequest = try XCTUnwrap(requests.first { $0.type == "cancelDownloadFile" })
        XCTAssertEqual(cancelRequest.object["only_if_pending"] as? Bool, false)
    }

    func testInactiveIncompleteSynchronousDownloadFails() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            transport?.respond(
                SyntheticFixtures.file(size: 12, completed: false, active: false, downloaded: 4),
                to: record
            )
        }
        await assertDomainError(.telegram(.downloadFailed)) {
            _ = try await withTimeout {
                try await gateway.downloadAudio(try syntheticAudio(size: 12)) { _ in }
            }
        }
        XCTAssertTrue(transport.sentRecords().contains { $0.type == "cancelDownloadFile" })
    }

    func testRequestTimeoutMapsToNetworkUnavailable() async throws {
        let transport = TestTransport()
        transport.setHandler { record in
            if record.type == "setAuthenticationPhoneNumber" {
                transport.respondOK(to: record)
                try? transport.emit(SyntheticFixtures.authUpdate("authorizationStateReady"))
            }
            if record.type == "getMe" { transport.respond(SyntheticFixtures.user(), to: record) }
        }
        let gateway = try TelegramGatewayClient(
            apiID: 12345,
            apiHash: SyntheticFixtures.apiHash,
            downloadDirectory: downloadDirectory,
            transport: transport,
            workspaceDirectory: workspace,
            databaseEncryptionKey: testDatabaseEncryptionKey,
            requestTimeout: 0.05
        )
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateWaitPhoneNumber"))
        try await waitForAuth(.waitingForPhone, from: gateway)
        try await gateway.submitPhone(SyntheticFixtures.phoneNumber)
        try await waitForAuth(.authenticated, from: gateway)
        await assertDomainError(.telegram(.networkUnavailable)) {
            _ = try await gateway.loadChats()
        }
    }

    func testRestoredSessionWaitsForVerifiedAccount() async throws {
        let transport = TestTransport()
        let gateway = try TelegramGatewayClient(
            apiID: 12345,
            apiHash: SyntheticFixtures.apiHash,
            downloadDirectory: downloadDirectory,
            transport: transport,
            workspaceDirectory: workspace,
            databaseEncryptionKey: testDatabaseEncryptionKey
        )
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateReady"))
        let request = try await transport.nextRequest(ofType: "getMe")
        let pendingState = await gateway.authState
        XCTAssertEqual(pendingState, .unauthenticated)
        let pendingAccount = await gateway.currentAccount
        XCTAssertNil(pendingAccount)
        transport.respond(SyntheticFixtures.user(), to: request)
        try await waitForAuth(.authenticated, from: gateway)
    }

    func testMalformedRequestResponseFailsPendingCallWithoutRawMessage() async throws {
        let transport = TestTransport()
        transport.setHandler { [weak transport] record in
            guard record.type == "setAuthenticationPhoneNumber" else { return }
            try? transport?.emit(["@type": "ok", "message": "synthetic-secret"], clientID: record.clientID)
        }
        let gateway = try TelegramGatewayClient(
            apiID: 12345,
            apiHash: SyntheticFixtures.apiHash,
            downloadDirectory: downloadDirectory,
            transport: transport,
            workspaceDirectory: workspace,
            databaseEncryptionKey: testDatabaseEncryptionKey
        )
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateWaitPhoneNumber"))
        try await waitForAuth(.waitingForPhone, from: gateway)
        await assertDomainError(.telegram(.invalidResponse)) {
            try await gateway.submitPhone(SyntheticFixtures.phoneNumber)
        }
    }

    func testConcurrentRequestsHaveUniqueIDsAndCompleteOutOfOrder() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway()
        let sent = XCTestExpectation(description: "All history requests sent")
        sent.expectedFulfillmentCount = 20
        transport.setHandler { [weak transport] record in
            guard record.type == "getChatHistory" else { return }
            sent.fulfill()
        }
        let tasks = (1...20).map { chatID in
            Task {
                try await gateway.loadAudioMessages(
                    try TelegramAudioPageRequest(chatID: Int64(chatID), beforeMessageID: nil, limit: 1)
                )
            }
        }
        await fulfillment(of: [sent], timeout: 3)
        let records = transport.sentRecords().filter { $0.type == "getChatHistory" }
        XCTAssertEqual(records.count, 20)
        XCTAssertEqual(Set(records.compactMap(\.extra)).count, 20)
        for record in records.reversed() {
            let chatID = try XCTUnwrap(record.object["chat_id"] as? Int)
            transport.respond([
                "@type": "messages",
                "messages": [SyntheticFixtures.audioMessage(id: Int64(chatID + 100), chatID: Int64(chatID))]
            ], to: record)
        }
        for task in tasks {
            let page = try await task.value
            XCTAssertEqual(page.messages.count, 1)
        }
    }

    func testCancelledRequestIgnoresLateResponseAndAllowsRetry() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway()
        let task = Task { try await gateway.loadChats() }
        let request = try await transport.nextRequest(ofType: "getChats")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        transport.respondOK(to: request)
        transport.setHandler { [weak transport] record in
            guard record.type == "getChats" else { return }
            transport?.respond(["@type": "chats", "total_count": 0, "chat_ids": []], to: record)
        }
        let chats = try await gateway.loadChats()
        XCTAssertTrue(chats.isEmpty)
    }

    func testConnectionCloseUsesTDLibRequestName() throws {
        let transport = TestTransport()
        let connection = TelegramConnection(transport: transport)
        connection.close()
        let request = try XCTUnwrap(transport.sentRecords().last)
        XCTAssertEqual(request.type, "close")
    }

    func testDownloadRejectsRegressiveProgress() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            transport?.respond(SyntheticFixtures.file(size: 12, downloaded: 4), to: record)
        }
        let recorder = ProgressRecorder()
        let audio = try syntheticAudio(size: 12)
        let task = Task { try await gateway.downloadAudio(audio) { recorder.record($0) } }
        _ = try await waitForProgress(recorder, count: 1)
        try transport.emit([
            "@type": "updateFile",
            "file": SyntheticFixtures.file(size: 12, downloaded: 8)
        ])
        _ = try await waitForProgress(recorder, count: 2)
        try transport.emit([
            "@type": "updateFile",
            "file": SyntheticFixtures.file(size: 12, downloaded: 6)
        ])
        await assertDomainError(.telegram(.invalidResponse)) {
            _ = try await task.value
        }
        XCTAssertEqual(recorder.snapshot().map(\.completedBytes), [4, 8])
    }

    func testUnknownDownloadSizeRemainsNilThroughCompletion() async throws {
        let payload = Data("synthetic".utf8)
        let filesDirectory = workspace.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let source = filesDirectory.appendingPathComponent("unknown-size-cache")
        try payload.write(to: source)
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            transport?.respond(
                SyntheticFixtures.file(
                    size: 0,
                    path: source.path,
                    completed: true,
                    downloaded: Int64(payload.count)
                ),
                to: record
            )
        }
        let audio = try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: 1, messageID: 7),
            fileID: 91,
            fileReference: "synthetic-file-reference",
            duration: 42,
            mimeType: "audio/mpeg"
        )
        let recorder = ProgressRecorder()
        _ = try await gateway.downloadAudio(audio) { recorder.record($0) }
        let last = try XCTUnwrap(recorder.snapshot().last)
        XCTAssertNil(last.totalBytes)
        XCTAssertEqual(last.completedBytes, Int64(payload.count))
    }

    func testSynchronousDownloadDoesNotUseShortRequestTimeout() async throws {
        let payload = Data("synthetic".utf8)
        let filesDirectory = workspace.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let source = filesDirectory.appendingPathComponent("slow-cache")
        try payload.write(to: source)
        let (gateway, transport) = try await makeAuthenticatedGateway(
            additional: { _ in },
            requestTimeout: 0.2
        )
        let audio = try syntheticAudio(size: Int64(payload.count))
        let task = Task { try await gateway.downloadAudio(audio) { _ in } }
        let request = try await transport.nextRequest(ofType: "downloadFile")
        let elapsed = XCTestExpectation(description: "Short request timeout elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { elapsed.fulfill() }
        await fulfillment(of: [elapsed], timeout: 1)
        transport.respond(
            SyntheticFixtures.file(
                size: Int64(payload.count),
                path: source.path,
                completed: true,
                downloaded: Int64(payload.count)
            ),
            to: request
        )
        _ = try await withTimeout { try await task.value }
    }

    func testClosingAuthorizationCancelsActiveDownloadAndPreservesWorkspace() async throws {
        let (gateway, transport) = try await makeAuthenticatedGateway(
            additional: { [weak transport] record in
                guard record.type == "downloadFile" else { return }
                transport?.respond(SyntheticFixtures.file(size: 12, downloaded: 4), to: record)
            }
        )
        let marker = workspace.appendingPathComponent("database/session")
        try Data("synthetic session".utf8).write(to: marker)
        let recorder = ProgressRecorder()
        let audio = try syntheticAudio(size: 12)
        let task = Task { try await gateway.downloadAudio(audio) { recorder.record($0) } }
        _ = try await waitForProgress(recorder, count: 1)
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateClosing"))
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateClosed"))
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        try await waitForAuth(.unauthenticated, from: gateway)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("synthetic session".utf8))
        let account = await gateway.currentAccount
        XCTAssertNil(account)
    }

    func testMalformedFileUpdateFailsOnlyMatchingDownload() async throws {
        let filesDirectory = workspace.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x2A, count: 12)
        let source = filesDirectory.appendingPathComponent("second-cache")
        try payload.write(to: source)
        let (gateway, transport) = try await makeAuthenticatedGateway { [weak transport] record in
            guard record.type == "downloadFile" else { return }
            let fileID = Int32(exactly: record.object["file_id"] as? Int ?? 0) ?? 0
            transport?.respond(SyntheticFixtures.file(id: fileID, size: 12, downloaded: 4), to: record)
        }
        let firstAudio = try syntheticAudio(size: 12)
        let secondAudio = try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: 1, messageID: 8),
            fileID: 92,
            fileReference: "synthetic-file-reference-2",
            duration: 42,
            fileSize: 12,
            mimeType: "audio/mpeg"
        )
        let firstRecorder = ProgressRecorder()
        let secondRecorder = ProgressRecorder()
        let firstTask = Task { try await gateway.downloadAudio(firstAudio) { firstRecorder.record($0) } }
        let secondTask = Task { try await gateway.downloadAudio(secondAudio) { secondRecorder.record($0) } }
        _ = try await waitForProgress(firstRecorder, count: 1)
        _ = try await waitForProgress(secondRecorder, count: 1)
        var malformed = SyntheticFixtures.file(id: 91, size: 12, downloaded: 8)
        malformed["local"] = ["downloaded_size": "not-an-integer"]
        try transport.emit(["@type": "updateFile", "file": malformed])
        await assertDomainError(.telegram(.invalidResponse)) {
            _ = try await firstTask.value
        }
        try transport.emit([
            "@type": "updateFile",
            "file": SyntheticFixtures.file(
                id: 92,
                size: 12,
                path: source.path,
                completed: true,
                downloaded: 12
            )
        ])
        _ = try await withTimeout { try await secondTask.value }
    }

    private func waitForProgress(
        _ recorder: ProgressRecorder,
        count: Int
    ) async throws -> [DownloadProgress] {
        try await withTimeout {
            var values: [DownloadProgress] = []
            for await value in recorder.updates {
                values.append(value)
                if values.count == count { return values }
            }
            throw TestFailure.timedOut
        }
    }

    private func makeWaitingGateway(
        user: [String: Any] = SyntheticFixtures.user(),
        additional: @escaping @Sendable (TransportRecord) -> Void = { _ in },
        requestTimeout: TimeInterval = 2
    ) throws -> (TelegramGatewayClient, TestTransport) {
        let transport = TestTransport()
        configureAuthentication(transport, user: user, additional: additional)
        let gateway = try TelegramGatewayClient(
            apiID: 12345,
            apiHash: SyntheticFixtures.apiHash,
            downloadDirectory: downloadDirectory,
            transport: transport,
            workspaceDirectory: workspace,
            databaseEncryptionKey: testDatabaseEncryptionKey,
            requestTimeout: requestTimeout
        )
        try transport.emit(SyntheticFixtures.authUpdate("authorizationStateWaitPhoneNumber"))
        return (gateway, transport)
    }

    private func makeAuthenticatedGateway(
        user: [String: Any] = SyntheticFixtures.user(),
        additional: @escaping @Sendable (TransportRecord) -> Void = { _ in },
        requestTimeout: TimeInterval = 2
    ) async throws -> (TelegramGatewayClient, TestTransport) {
        let (gateway, transport) = try makeWaitingGateway(
            user: user,
            additional: additional,
            requestTimeout: requestTimeout
        )
        try await authenticate(gateway)
        return (gateway, transport)
    }

    private func authenticate(_ gateway: TelegramGatewayClient) async throws {
        try await gateway.submitPhone(SyntheticFixtures.phoneNumber)
        try await waitForAuth(.waitingForCode, from: gateway)
        try await gateway.submitCode(String(repeating: "1", count: 6))
        try await waitForAuth(.waitingForPassword, from: gateway)
        try await gateway.submitPassword(SyntheticFixtures.password)
        try await waitForAuth(.authenticated, from: gateway)
    }

    private func configureAuthentication(
        _ transport: TestTransport,
        user: [String: Any],
        additional: @escaping @Sendable (TransportRecord) -> Void
    ) {
        transport.setHandler { [weak transport] record in
            switch record.type {
            case "setAuthenticationPhoneNumber":
                transport?.respondOK(to: record)
                try? transport?.emit(SyntheticFixtures.authUpdate("authorizationStateWaitCode"))
            case "checkAuthenticationCode":
                transport?.respondOK(to: record)
                try? transport?.emit(SyntheticFixtures.authUpdate("authorizationStateWaitPassword"))
            case "checkAuthenticationPassword":
                transport?.respondOK(to: record)
                try? transport?.emit(SyntheticFixtures.authUpdate("authorizationStateReady"))
            case "getMe":
                transport?.respond(user, to: record)
            default:
                additional(record)
            }
        }
    }

    private func syntheticAudio(size: Int64) throws -> TelegramAudio {
        try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: 1, messageID: 7),
            fileID: 91,
            fileReference: "synthetic-file-reference",
            duration: 42,
            fileSize: size,
            mimeType: "audio/mpeg"
        )
    }
}
