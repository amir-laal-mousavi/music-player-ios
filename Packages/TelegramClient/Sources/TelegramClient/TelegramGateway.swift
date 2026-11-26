import Foundation
import MusicCore
#if canImport(Security)
import Security
#endif

public actor TelegramGatewayClient: TelegramGateway {
    private let apiID: Int32

    private var apiHash: String?
    private let downloadDirectory: SafeDownloadDirectory
    private let sourceDirectory: URL
    private let workspaceDirectory: URL
    private var databaseEncryptionKey: Data?
    private let connection: TelegramConnection
    private let requestTimeout: TimeInterval
    private var eventTask: Task<Void, Never>?

    public private(set) var authState: TelegramAuthState = .unauthenticated
    private var account: TelegramAccount?
    private var observers: [UUID: AsyncStream<TelegramAuthState>.Continuation] = [:]
    private var pendingRequests: [String: PendingRequest] = [:]
    private var activeDownloads: [TelegramAudioIdentity: ActiveDownload] = [:]
    private var parametersSent = false
    private var authenticationInProgress = false
    private var stopped = false

#if canImport(TDLibFramework)
    public convenience init(
        apiID: Int32,
        apiHash: String,
        downloadDirectory: URL,
        workspaceDirectory: URL? = nil
    ) throws {
        let configuration = try Self.persistentWorkspaceConfiguration(workspaceDirectory: workspaceDirectory)
        try self.init(
            apiID: apiID,
            apiHash: apiHash,
            downloadDirectory: downloadDirectory,
            transport: TDLibTransport(),
            workspaceDirectory: configuration.workspace,
            databaseEncryptionKey: configuration.encryptionKey,
            requestTimeout: 30
        )
    }
#endif

    internal init(
        apiID: Int32,
        apiHash: String,
        downloadDirectory: URL,
        transport: TelegramTransport,
        workspaceDirectory: URL,
        databaseEncryptionKey: Data,
        requestTimeout: TimeInterval = 2
    ) throws {
        guard apiID > 0,
              !apiHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              databaseEncryptionKey.count == 32,
              requestTimeout.isFinite,
              requestTimeout > 0,
              requestTimeout <= 3_600 else {
            throw DomainError.telegram(.invalidResponse)
        }
        let workspace = try Self.prepareWorkspace(workspaceDirectory)
        let filesDirectory = workspace.appendingPathComponent("files", isDirectory: true)
        self.apiID = apiID
        self.apiHash = apiHash
        self.downloadDirectory = try SafeDownloadDirectory(directory: downloadDirectory)
        self.sourceDirectory = filesDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.workspaceDirectory = workspace
        self.databaseEncryptionKey = databaseEncryptionKey
        self.requestTimeout = requestTimeout
        let connection = TelegramConnection(transport: transport)
        self.connection = connection

        var iterator = connection.events.makeAsyncIterator()
        eventTask = Task { [weak self] in
            while true {
                let next = try? await iterator.next()
                guard let self else { return }
                guard let event = next else {
                    await self.finishTransport()
                    return
                }
                await self.handle(event)
                if await self.stopped { return }
            }
        }
    }

    deinit {
        eventTask?.cancel()
        connection.close()
    }

    public var currentAccount: TelegramAccount? {
        account
    }

    public nonisolated func observeAuthState() -> AsyncStream<TelegramAuthState> {
        let id = UUID()
        let lifetime = ObserverLifetime()
        let (stream, continuation) = AsyncStream<TelegramAuthState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            lifetime.cancel()
            Task { await self?.removeObserver(id) }
        }
        Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.addObserver(id, continuation: continuation, lifetime: lifetime)
        }
        return stream
    }

    public func submitPhone(_ phone: String) async throws {
        let phone = try validatedPhoneNumber(phone)
        guard authState == .waitingForPhone else { throw DomainError.unauthenticated }
        try await submitAuthentication(
            "setAuthenticationPhoneNumber",
            parameters: [
                "phone_number": phone,
                "settings": NSNull()
            ]
        )
    }

    public func submitCode(_ code: String) async throws {
        let code = try validatedAuthenticationCode(code)
        guard authState == .waitingForCode else { throw DomainError.unauthenticated }
        try await submitAuthentication(
            "checkAuthenticationCode",
            parameters: ["code": code]
        )
    }

    public func submitPassword(_ password: String) async throws {
        let password = try validatedPassword(password)
        guard authState == .waitingForPassword else { throw DomainError.unauthenticated }
        try await submitAuthentication(
            "checkAuthenticationPassword",
            parameters: ["password": password]
        )
    }

    public func logout() async throws {
        try Task.checkCancellation()
        guard authState == .authenticated else { throw DomainError.unauthenticated }
        account = nil
        cancelAllDownloads()
        transition(.loggingOut)
        do {
            let data = try await performRequest(
                ["@type": "logOut"],
                notFound: DomainError.unauthenticated
            )
            try TDLibMapper.requireOK(data)
        } catch {
            await recordFailure(error)
            throw error
        }
    }

    public func loadChats() async throws -> [TelegramChat] {
        try requireAuthenticated()
        let data = try await performRequest([
            "@type": "getChats",
            "chat_list": ["@type": "chatListMain"],
            "limit": 100
        ])
        let response = try responseObject(data, expectedType: "chats")
        let ids = try TDLibJSON.array(response["chat_ids"])
        var chats: [TelegramChat] = []
        for value in ids {
            try Task.checkCancellation()
            let id = try TDLibJSON.int64(value)
            let chatData = try await performRequest(
                ["@type": "getChat", "chat_id": id],
                notFound: .chatNotFound(id)
            )
            chats.append(try TDLibMapper.chat(from: responseObject(chatData, expectedType: "chat")))
        }
        return chats
    }

    public func loadAudioMessages(_ request: TelegramAudioPageRequest) async throws -> TelegramAudioPage {
        try requireAuthenticated()
        var before = request.beforeMessageID
        var messages: [TelegramAudio] = []
        var seen = Set<Int64>()
        while messages.count < request.limit {
            try Task.checkCancellation()
            let data = try await performRequest(
                [
                    "@type": "getChatHistory",
                    "chat_id": request.chatID,
                    "from_message_id": before ?? 0,
                    "offset": "0",
                    "limit": request.limit,
                    "only_local": false
                ],
                notFound: .chatNotFound(request.chatID)
            )
            let response = try responseObject(data, expectedType: "messages")
            let batch = try TDLibJSON.array(response["messages"])
            // A batch shorter than the requested limit is the end of the chat's history.
            let isFinalBatch = batch.count < request.limit
            let page = try TDLibMapper.page(messages: batch, request: request)
            for audio in page.messages where seen.insert(audio.messageID).inserted {
                messages.append(audio)
            }
            if messages.count >= request.limit || isFinalBatch { break }
            guard let oldest = try TDLibMapper.oldestMessageID(
                messages: batch,
                chatID: request.chatID,
                beforeMessageID: before
            ) else { break }
            before = oldest
        }
        let limited = Array(messages.sorted { $0.messageID > $1.messageID }.prefix(request.limit))
        return try TelegramAudioPage(
            chatID: request.chatID,
            messages: limited,
            nextCursor: limited.last?.messageID
        )
    }

    public func downloadAudio(
        _ audio: TelegramAudio,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        try requireAuthenticated()
        try Task.checkCancellation()
        guard activeDownloads[audio.identity] == nil else {
            throw DomainError.telegram(.downloadFailed)
        }
        let sessionID = UUID()
        let cancellation = DownloadCancellationToken()
        let events = DownloadEvents()
        let task = Task {
            try await performDownload(
                audio: audio,
                sessionID: sessionID,
                cancellation: cancellation,
                events: events,
                progress: progress
            )
        }
        activeDownloads[audio.identity] = ActiveDownload(
            sessionID: sessionID,
            fileID: audio.fileID,
            cancellation: cancellation,
            events: events,
            task: task
        )
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            events.finish(error: CancellationError())
            task.cancel()
        }
    }

    public func downloadThumbnail(_ thumbnail: TelegramThumbnail) async throws -> URL? {
        try requireAuthenticated()
        try Task.checkCancellation()
        let data = try await performRequest(
            [
                "@type": "downloadFile",
                "file_id": thumbnail.fileID,
                "priority": 1,
                "offset": 0,
                "limit": 0,
                "synchronous": true
            ],
            notFound: nil,
            timesOut: false
        )
        let file = try TDLibMapper.file(from: responseObject(data, expectedType: "file"))
        guard file.isCompleted, !file.localPath.isEmpty else { return nil }
        return URL(fileURLWithPath: file.localPath)
    }

    public func cancelDownload(for identity: TelegramAudioIdentity) async {
        guard let download = activeDownloads[identity] else { return }
        download.cancellation.cancel()
        download.events.finish(error: CancellationError())
        download.task.cancel()
        _ = try? await download.task.value
    }

    internal static func persistentWorkspaceConfiguration(
        workspaceDirectory: URL? = nil,
        loadOrCreateKey: (URL) throws -> Data = databaseEncryptionKey(for:)
    ) throws -> (workspace: URL, encryptionKey: Data) {
        let workspace = try workspaceDirectory.map(Self.prepareWorkspace) ?? Self.makeWorkspace()
        let encryptionKey = try loadOrCreateKey(workspace)
        guard encryptionKey.count == 32 else { throw DomainError.telegram(.invalidResponse) }
        return (workspace, encryptionKey)
    }

    private static func makeWorkspace() throws -> URL {
        let workspace = try defaultWorkspaceDirectory()
        return try prepareWorkspace(workspace)
    }

    internal static func defaultWorkspaceDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DomainError.telegram(.invalidResponse)
        }
        return applicationSupport.appendingPathComponent("TelegramClient", isDirectory: true)
    }

    private static func prepareWorkspace(_ workspace: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(
            at: workspace.appendingPathComponent("database", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.createDirectory(
            at: workspace.appendingPathComponent("files", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return workspace.resolvingSymlinksInPath().standardizedFileURL
    }

    internal static func databaseEncryptionKey(for workspace: URL) throws -> Data {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MusicPlayer.TelegramClient.database",
            kSecAttrAccount as String: workspace.path,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        func copiedKey(_ status: OSStatus, _ result: CFTypeRef?) throws -> Data {
            guard status == errSecSuccess,
                  let data = result as? Data,
                  data.count == 32 else {
                throw DomainError.telegram(.invalidResponse)
            }
            return data
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            // TDLib rejects an existing database when its encryption key changes.
            var bytes = [UInt8](repeating: 0, count: 32)
            let count = bytes.count
            let randomStatus = bytes.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
            }
            guard randomStatus == errSecSuccess else { throw DomainError.telegram(.invalidResponse) }
            let key = Data(bytes)
            var item = query
            item[kSecValueData as String] = key
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                var existing: CFTypeRef?
                return try copiedKey(SecItemCopyMatching(query as CFDictionary, &existing), existing)
            }
            guard addStatus == errSecSuccess else { throw DomainError.telegram(.invalidResponse) }
            return key
        }
        return try copiedKey(status, result)
        #else
        throw DomainError.telegram(.invalidResponse)
        #endif
    }

    private func addObserver(
        _ id: UUID,
        continuation: AsyncStream<TelegramAuthState>.Continuation,
        lifetime: ObserverLifetime
    ) {
        guard !lifetime.isCancelled else { return }
        guard !stopped else {
            continuation.yield(authState)
            continuation.finish()
            return
        }
        observers[id] = continuation
        continuation.yield(authState)
        if lifetime.isCancelled {
            observers.removeValue(forKey: id)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyObservers() {
        for continuation in observers.values {
            continuation.yield(authState)
        }
    }

    private func transition(_ next: TelegramAuthState) {
        guard authState != next else { return }
        do {
            authState = try authState.transition(to: next)
            if next != .authenticated { account = nil }
            if next == .loggingOut { cancelAllDownloads() }
            notifyObservers()
        } catch {
            account = nil
            cancelAllDownloads()
            let domain = error as? DomainError ?? .telegram(.invalidResponse)
            if authState.canTransition(to: .failure(domain)) {
                authState = .failure(domain)
                notifyObservers()
            }
        }
    }

    private func requireAuthenticated() throws {
        guard authState == .authenticated, account != nil, !stopped else {
            throw DomainError.unauthenticated
        }
    }

    private func submitAuthentication(_ type: String, parameters: [String: Any]) async throws {
        var request = parameters
        request["@type"] = type
        do {
            let data = try await performRequest(request, notFound: .unauthenticated)
            try TDLibMapper.requireOK(data)
        } catch {
            if let domain = error as? DomainError, domain == .unauthenticated {
                await recordFailure(domain)
            }
            throw error
        }
    }

    private func handle(_ data: Data) async {
        guard !stopped else { return }
        do {
            let object = try TDLibJSON.object(from: data)
            let type = try TDLibJSON.string(object["@type"])
            if type == "updateFile" {
                handleFileUpdate(object)
                return
            }
            if let extra = object["@extra"] as? String {
                finishPendingRequest(extra, object: object)
                return
            }
            if type == "ok" || type == "error" {
                // @extra was absent — malformed response from TDLib
                throw TDLibJSON.invalidResponse
            }
            if type == "updateAuthorizationState" {
                let state = try TDLibMapper.authorizationStateObject(from: object)
                if try TDLibJSON.string(state["@type"]) == "authorizationStateClosed" {
                    await closeSession(.unauthenticated)
                } else {
                    try handleAuthorizationState(try TDLibMapper.authState(from: state))
                }
                return
            }
        } catch {
            await recordFailure(error)
        }
    }

    private func handleAuthorizationState(_ next: TelegramAuthState) throws {
        switch next {
        case .unauthenticated:
            sendTDLibParameters()
        case .waitingForPhone:
            transition(.waitingForPhone)
        case .waitingForCode:
            transition(.waitingForCode)
        case .waitingForPassword:
            transition(.waitingForPassword)
        case .authenticated:
            beginAuthentication()
        case .loggingOut:
            transition(.loggingOut)
        case .failure:
            transition(.failure(.telegram(.invalidResponse)))
        }
    }

    private func beginAuthentication() {
        guard !authenticationInProgress, authState != .authenticated, !stopped else { return }
        authenticationInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await performRequest(["@type": "getMe"], notFound: .unauthenticated)
                let current = try TDLibMapper.account(from: responseObject(data, expectedType: "user"))
                await completeAuthentication(current)
            } catch {
                await recordFailure(error)
            }
        }
    }

    private func completeAuthentication(_ current: TelegramAccount) async {
        guard authenticationInProgress, !stopped else { return }
        authenticationInProgress = false
        account = current
        transition(.authenticated)
    }

    private func recordFailure(_ error: Error) async {
        guard !stopped, !(error is CancellationError) else { return }
        let domain = error as? DomainError ?? DomainError.telegram(.invalidResponse)
        authenticationInProgress = false
        finishPendingRequests(domain)
        if case .failure = authState { return }
        account = nil
        cancelAllDownloads()
        transition(.failure(domain))
    }

    private nonisolated func responseObject(_ data: Data, expectedType: String) throws -> [String: Any] {
        let object = try TDLibJSON.object(from: data)
        guard try TDLibJSON.string(object["@type"]) == expectedType else {
            throw TDLibJSON.invalidResponse
        }
        return object
    }

    private func sendTDLibParameters() {
        guard !parametersSent, !stopped, let apiHash, let encryptionKey = databaseEncryptionKey else { return }
        parametersSent = true
        self.apiHash = nil
        databaseEncryptionKey = nil
        let workspace = workspaceDirectory
        let files = sourceDirectory
        let id = apiID
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await performRequest(
                    [
                        "@type": "setTdlibParameters",
                        "use_test_dc": false,
                        "database_directory": workspace.appendingPathComponent("database").path,
                        "files_directory": files.path,
                        "database_encryption_key": encryptionKey.base64EncodedString(),
                        "use_file_database": true,
                        "use_chat_info_database": true,
                        "use_message_database": true,
                        "use_secret_chats": false,
                        "api_id": id,
                        "api_hash": apiHash,
                        "system_language_code": "en",
                        "device_model": "iOS",
                        "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
                        "application_version": "2"
                    ],
                    notFound: .unauthenticated
                )
                try TDLibMapper.requireOK(data)
            } catch {
                await recordFailure(error)
            }
        }
    }

    private func performRequest(
        _ request: [String: Any],
        notFound: DomainError? = nil,
        timesOut: Bool = true
    ) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped else { throw DomainError.unauthenticated }
        let extra = UUID().uuidString
        var request = request
        request["@extra"] = extra
        let data = try TDLibJSON.encode(request)
        let pending = PendingRequest(notFound: notFound)
        pendingRequests[extra] = pending
        if timesOut {
            let timeoutNanoseconds = UInt64(requestTimeout * 1_000_000_000)
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                await self?.finishPendingRequest(
                    extra,
                    result: .failure(DomainError.telegram(.networkUnavailable))
                )
            }
            pending.setTimeoutTask(timeoutTask)
        }
        connection.send(data)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.attach(continuation)
                }
            } onCancel: {
                pending.complete(.failure(CancellationError()))
            }
        } catch {
            abandonRequest(extra)
            throw error
        }
    }

    private func finishPendingRequest(_ extra: String, object: [String: Any]) {
        guard let pending = pendingRequests.removeValue(forKey: extra) else { return }
        do {
            let type = try TDLibJSON.string(object["@type"])
            if type == "error" {
                let code = try TDLibJSON.int32(object["code"])
                let mapped = code == 404 ? pending.notFound : nil
                pending.complete(.failure(mapped ?? TDLibMapper.error(code: code)))
            } else {
                pending.complete(.success(try TDLibJSON.encode(object)))
            }
        } catch {
            pending.complete(.failure(error))
        }
    }

    private func finishPendingRequest(_ extra: String, result: PendingRequest.Completion) {
        pendingRequests.removeValue(forKey: extra)?.complete(result)
    }

    private func abandonRequest(_ extra: String) {
        pendingRequests.removeValue(forKey: extra)?.cancelTimeout()
    }

    private func handleFileUpdate(_ object: [String: Any]) {
        let file: [String: Any]
        let fileID: Int32
        do {
            file = try TDLibJSON.object(object["file"])
            fileID = try TDLibJSON.int32(file["id"])
        } catch {
            failDownloads(DomainError.telegram(.invalidResponse))
            return
        }
        let downloads = activeDownloads.values.filter { $0.fileID == fileID }
        guard !downloads.isEmpty else { return }
        do {
            let snapshot = DownloadFileSnapshot(file: try TDLibMapper.file(from: file))
            for download in downloads {
                download.events.yield(snapshot)
            }
        } catch {
            failDownloads(error, fileID: fileID)
        }
    }

    private func fileSnapshot(_ object: [String: Any]) throws -> DownloadFileSnapshot {
        DownloadFileSnapshot(file: try TDLibMapper.file(from: object))
    }

    private func performDownload(
        audio: TelegramAudio,
        sessionID: UUID,
        cancellation: DownloadCancellationToken,
        events: DownloadEvents,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        var failed = true
        let result: Swift.Result<URL, Error>
        do {
            result = .success(try await copyDownload(
                audio: audio,
                cancellation: cancellation,
                events: events,
                progress: progress
            ))
            failed = false
        } catch {
            let failure: Error = (error as? DomainError)
                ?? (events.storedError as? DomainError)
                ?? (error is CancellationError ? error : DomainError.telegram(.downloadFailed))
            result = .failure(failure)
        }
        await finishDownload(audio.identity, sessionID: sessionID, failed: failed)
        return try result.get()
    }

    private func copyDownload(
        audio: TelegramAudio,
        cancellation: DownloadCancellationToken,
        events: DownloadEvents,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let data = try await performRequest(
            [
                "@type": "downloadFile",
                "file_id": audio.fileID,
                "priority": 16,
                "offset": 0,
                "limit": 0,
                "synchronous": true
            ],
            notFound: .audioNotFound(audio.identity),
            timesOut: false
        )
        var current = try fileSnapshot(responseObject(data, expectedType: "file"))
        var reported: DownloadProgress?
        var iterator = events.stream.makeAsyncIterator()
        while true {
            try cancellation.withLock {}
            try Task.checkCancellation()
            guard current.file.id == audio.fileID else {
                throw DomainError.telegram(.invalidResponse)
            }
            if let fileSize = audio.fileSize, fileSize > 0,
               current.file.size > 0, current.file.size != fileSize {
                throw DomainError.telegram(.downloadFailed)
            }
            guard current.file.isCompleted || current.file.isDownloadingActive else {
                throw DomainError.telegram(.downloadFailed)
            }
            let next = try TDLibMapper.progress(file: current.file, knownTotal: audio.fileSize)
            if let reported, next.completedBytes < reported.completedBytes {
                throw DomainError.telegram(.invalidResponse)
            }
            if next != reported {
                try cancellation.withLock {
                    progress(next)
                    reported = next
                }
            }
            if current.file.isCompleted { break }
            guard let update = try await iterator.next() else {
                throw DomainError.telegram(.downloadFailed)
            }
            current = update
        }
        guard !current.file.localPath.isEmpty else {
            throw DomainError.telegram(.downloadFailed)
        }
        let exactSize = audio.fileSize.flatMap { $0 > 0 ? $0 : nil }
            ?? (current.file.size > 0 ? current.file.size : nil)
        let expectedSize = exactSize ?? (current.file.expectedSize > 0 ? current.file.expectedSize : nil)
        let directory = downloadDirectory
        let sourceRoot = sourceDirectory
        let source = URL(fileURLWithPath: current.file.localPath)
        let fileExtension = DownloadFileNaming.fileExtension(forMimeType: audio.mimeType)
        let staged = try await Task.detached(priority: .utility) {
            try directory.stage(
                source: source,
                sourceRoot: sourceRoot,
                expectedSize: exactSize,
                fileExtension: fileExtension,
                cancellation: cancellation
            )
        }.value
        var publishedName: String?
        do {
            let destination = try downloadDirectory.publish(staged, cancellation: cancellation)
            publishedName = destination.lastPathComponent
            let completed = min(staged.bytesCopied, expectedSize ?? staged.bytesCopied)
            let finalProgress = try DownloadProgress(totalBytes: expectedSize, completedBytes: completed)
            if let reported, finalProgress.completedBytes < reported.completedBytes {
                throw DomainError.telegram(.invalidResponse)
            }
            if finalProgress != reported {
                try cancellation.withLock { progress(finalProgress) }
            }
            return destination
        } catch {
            staged.cleanup()
            if let publishedName { downloadDirectory.remove(publishedName) }
            throw error
        }
    }

    private func finishDownload(
        _ identity: TelegramAudioIdentity,
        sessionID: UUID,
        failed: Bool
    ) async {
        guard let active = activeDownloads[identity], active.sessionID == sessionID else { return }
        activeDownloads.removeValue(forKey: identity)
        active.events.finish()
        if failed && !activeDownloads.values.contains(where: { $0.fileID == active.fileID }) {
            cleanupTDLibFile(active.fileID)
        }
    }

    private func cleanupTDLibFile(_ fileID: Int32) {
        guard !stopped else { return }
        for type in ["cancelDownloadFile", "deleteFile"] {
            var request: [String: Any] = [
                "@type": type,
                "file_id": fileID,
                "@extra": UUID().uuidString
            ]
            if type == "cancelDownloadFile" { request["only_if_pending"] = false }
            guard let data = try? TDLibJSON.encode(request) else { continue }
            connection.send(data)
        }
    }

    private func cancelAllDownloads() {
        for download in activeDownloads.values {
            download.cancellation.cancel()
            download.events.finish(error: CancellationError())
            download.task.cancel()
        }
    }

    private func cancelAndAwaitDownloads() async {
        cancelAllDownloads()
        let tasks = activeDownloads.values.map(\.task)
        for task in tasks {
            _ = try? await task.value
        }
    }

    private func failDownloads(_ error: Error, fileID: Int32? = nil) {
        for download in activeDownloads.values where fileID.map({ $0 == download.fileID }) ?? true {
            download.cancellation.cancel()
            download.events.finish(error: error)
            download.task.cancel()
        }
    }

    private func finishTransport() async {
        guard !stopped else { return }
        await recordFailure(DomainError.telegram(.invalidResponse))
        finishPendingRequests()
        stopped = true
        finishObservers()
        await cancelAndAwaitDownloads()
        connection.close()
    }

    private func closeSession(_ error: DomainError) async {
        guard !stopped else { return }
        authenticationInProgress = false
        if authState != .unauthenticated {
            if authState.canTransition(to: .unauthenticated) {
                transition(.unauthenticated)
            } else {
                transition(.failure(error))
                transition(.unauthenticated)
            }
        }
        account = nil
        failDownloads(error)
        finishPendingRequests(error)
        stopped = true
        finishObservers()
        await cancelAndAwaitDownloads()
    }

    private func finishPendingRequests(_ error: DomainError = .telegram(.invalidResponse)) {
        for pending in pendingRequests.values {
            pending.complete(.failure(error))
        }
        pendingRequests.removeAll()
    }

    private func finishObservers() {
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }
}

private final class ObserverLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct ActiveDownload {
    let sessionID: UUID
    let fileID: Int32
    let cancellation: DownloadCancellationToken
    let events: DownloadEvents
    let task: Task<URL, Error>
}

private struct DownloadFileSnapshot: Sendable {
    let file: TDLibFile
}

private final class DownloadEvents: @unchecked Sendable {
    let stream: AsyncThrowingStream<DownloadFileSnapshot, Error>
    private let continuation: AsyncThrowingStream<DownloadFileSnapshot, Error>.Continuation
    private let lock = NSLock()
    private var terminalError: Error?

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    var storedError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }

    func yield(_ snapshot: DownloadFileSnapshot) {
        continuation.yield(snapshot)
    }

    func finish(error: Error? = nil) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        lock.unlock()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}

private final class PendingRequest: @unchecked Sendable {
    typealias Completion = Swift.Result<Data, Error>

    let notFound: DomainError?
    private let lock = NSLock()
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed = false
    private var outcome: Completion?

    init(notFound: DomainError?) {
        self.notFound = notFound
    }

    func attach(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    func cancelTimeout() {
        lock.lock()
        timeoutTask?.cancel()
        lock.unlock()
    }

    func complete(_ result: Completion) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        if continuation == nil { outcome = result }
        timeoutTask?.cancel()
        lock.unlock()
        continuation?.resume(with: result)
    }
}
