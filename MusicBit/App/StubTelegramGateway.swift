#if DEBUG
import Foundation
import MusicCore

/// Deterministic, offline Telegram stand-in used by UI tests (`-uiTesting`).
///
/// It signs in with any non-empty phone number and code, serves a fixed chat list with
/// descending audio pages, and "downloads" a silent WAV so the whole import and playback
/// flow runs without network access or real credentials.
actor StubTelegramGateway: TelegramGateway {
    static let chatIDs: [TelegramChat.ID] = [1001, 1002, 1003]

    private var phase: TelegramAuthState = .waitingForPhone
    private var authObservers: [UUID: AsyncStream<TelegramAuthState>.Continuation] = [:]

    private let chats: [TelegramChat]
    private let audiosByChat: [TelegramChat.ID: [TelegramAudio]]
    private let downloadDirectory: URL
    private let account: TelegramAccount?

    init() {
        chats = Self.makeChats()
        audiosByChat = Self.makeAudios()
        account = try? TelegramAccount(
            id: 9001,
            displayName: "MusicBit Tester",
            phoneNumber: "+15550101234"
        )
        downloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBitStubDownloads-\(UUID().uuidString)", isDirectory: true)
    }

    var authState: TelegramAuthState { phase }
    var currentAccount: TelegramAccount? { account }

    nonisolated func observeAuthState() -> AsyncStream<TelegramAuthState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { [weak self] in await self?.addAuthObserver(id, continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeAuthObserver(id) }
            }
        }
    }

    func submitPhone(_ phone: String) async throws {
        _ = try validatedPhoneNumber(phone)
        transition(to: .waitingForCode)
    }

    func submitCode(_ code: String) async throws {
        _ = try validatedAuthenticationCode(code)
        transition(to: .authenticated)
    }

    func submitPassword(_ password: String) async throws {
        _ = try validatedPassword(password)
        transition(to: .authenticated)
    }

    func logout() async throws {
        transition(to: .waitingForPhone)
    }

    func loadChats() async throws -> [TelegramChat] {
        try requireAuthentication()
        return chats
    }

    func loadAudioMessages(_ request: TelegramAudioPageRequest) async throws -> TelegramAudioPage {
        try requireAuthentication()
        let all = audiosByChat[request.chatID] ?? []
        let remaining = request.beforeMessageID.map { cursor in
            all.filter { $0.messageID < cursor }
        } ?? all
        let slice = Array(remaining.prefix(request.limit))
        let nextCursor = remaining.count > slice.count ? slice.last?.messageID : nil
        return try TelegramAudioPage(chatID: request.chatID, messages: slice, nextCursor: nextCursor)
    }

    func downloadAudio(
        _ audio: TelegramAudio,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        try requireAuthentication()
        let data = StubAudioFile.silentWAV(seconds: audio.duration)
        try FileManager.default.createDirectory(
            at: downloadDirectory,
            withIntermediateDirectories: true
        )
        let url = downloadDirectory.appendingPathComponent("stub-\(audio.chatID)-\(audio.messageID).wav")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)

        let total = Int64(data.count)
        try? progress(DownloadProgress(totalBytes: total, completedBytes: total / 2))
        try? progress(DownloadProgress(totalBytes: total, completedBytes: total))
        return url
    }

    func cancelDownload(for identity: TelegramAudioIdentity) async {}

    private func requireAuthentication() throws {
        guard phase == .authenticated else { throw DomainError.telegram(.notAuthorized) }
    }

    private func transition(to next: TelegramAuthState) {
        phase = next
        for continuation in authObservers.values { continuation.yield(next) }
    }

    private func addAuthObserver(
        _ id: UUID,
        _ continuation: AsyncStream<TelegramAuthState>.Continuation
    ) {
        authObservers[id] = continuation
        if case .terminated = continuation.yield(phase) { authObservers[id] = nil }
    }

    private func removeAuthObserver(_ id: UUID) {
        authObservers[id] = nil
    }

    private static func makeChats() -> [TelegramChat] {
        [
            try? TelegramChat(id: 1001, title: "Focus", kind: .group),
            try? TelegramChat(id: 1002, title: "Sunset Drive", kind: .channel),
            try? TelegramChat(id: 1003, title: "Saved Messages", kind: .user)
        ].compactMap { $0 }
    }

    private static func makeAudios() -> [TelegramChat.ID: [TelegramAudio]] {
        var result: [TelegramChat.ID: [TelegramAudio]] = [:]
        let catalog: [(TelegramChat.ID, [String])] = [
            (1001, ["Night Drive", "Morning Static", "Low Orbit"]),
            (1002, ["Harbour Lights", "Slow Tide"]),
            (1003, ["Draft Sketch"])
        ]
        for (chatID, titles) in catalog {
            var list: [TelegramAudio] = []
            // Newest first, so message 103 is the first row UI tests see.
            for (index, title) in titles.enumerated() {
                let messageID = Int64(100 + titles.count - index)
                guard
                    let identity = try? TelegramAudioIdentity(chatID: chatID, messageID: messageID),
                    let audio = try? TelegramAudio(
                        identity: identity,
                        fileID: Int32(messageID % 1000),
                        fileReference: "stub-ref-\(chatID)-\(messageID)",
                        title: title,
                        performer: "Stub Artist",
                        duration: 2,
                        fileSize: nil,
                        mimeType: "audio/wav"
                    )
                else { continue }
                list.append(audio)
            }
            result[chatID] = list
        }
        return result
    }
}

/// Builds a small, valid, silent 16-bit PCM WAV the player can actually open.
enum StubAudioFile {
    static func silentWAV(seconds: TimeInterval) -> Data {
        let sampleRate = 8_000
        let safeSeconds = seconds.isFinite && seconds > 0 ? min(seconds, 30) : 1
        let frameCount = max(1, Int(safeSeconds.rounded(.up) * Double(sampleRate)))
        let dataSize = frameCount * 2

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)                                  // PCM
        append(UInt16(1), to: &data)                                  // mono
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)                     // byte rate
        append(UInt16(2), to: &data)                                  // block align
        append(UInt16(16), to: &data)                                 // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize), to: &data)
        data.append(Data(count: dataSize))
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
#endif
