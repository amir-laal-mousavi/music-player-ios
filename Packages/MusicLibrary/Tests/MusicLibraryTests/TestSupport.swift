import Foundation
import MusicCore
import XCTest
@testable import MusicLibrary

enum TestSupport {
    static let chat = try! TelegramChat(id: 42, title: "Test chat", kind: .group)

    static func audio(
        messageID: Int64 = 1,
        fileSize: Int64? = 4,
        mimeType: String? = "audio/mpeg"
    ) -> TelegramAudio {
        try! TelegramAudio(
            identity: TelegramAudioIdentity(chatID: chat.id, messageID: messageID),
            fileID: Int32(messageID),
            fileReference: "reference-\(messageID)",
            title: "Track \(messageID)",
            performer: "Artist",
            duration: 123,
            fileSize: fileSize,
            mimeType: mimeType
        )
    }

    static func track(
        id: UUID = UUID(),
        messageID: Int64 = 1,
        importedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        localURL: URL? = nil
    ) -> Track {
        try! Track(
            id: id,
            telegramIdentity: audio(messageID: messageID).identity,
            sourceChat: chat,
            title: "Track \(messageID)",
            artist: "Artist",
            duration: 123,
            fileSize: 4,
            importedAt: importedAt,
            localURL: localURL ?? URL(fileURLWithPath: "/tmp/\(id.uuidString).mp3")
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

actor FakeTelegramGateway: TelegramGateway {
    private let directory: URL
    private let started: AsyncStream<TelegramAudioIdentity>
    private let startedContinuation: AsyncStream<TelegramAudioIdentity>.Continuation
    private var authentication: TelegramAuthState = .authenticated
    private var downloaded: [TelegramAudio] = []
    private var errors: [TelegramAudioIdentity: TelegramGatewayError] = [:]
    private var deferred: Set<TelegramAudioIdentity> = []
    private var cancelled: Set<TelegramAudioIdentity> = []
    private var activeCancellations: Set<TelegramAudioIdentity> = []
    private var pending: [TelegramAudioIdentity: CheckedContinuation<URL, Error>] = [:]
    private var progressHandlers: [TelegramAudioIdentity: @Sendable (DownloadProgress) -> Void] = [:]

    init(directory: URL) {
        self.directory = directory
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    var startedDownloads: AsyncStream<TelegramAudioIdentity> { started }
    var downloadCount: Int { downloaded.count }
    var cancelledDownloads: Set<TelegramAudioIdentity> { cancelled }

    var authState: TelegramAuthState { authentication }
    var currentAccount: TelegramAccount? { nil }

    func setAuthState(_ state: TelegramAuthState) {
        authentication = state
    }

    func setError(_ error: TelegramGatewayError?, for identity: TelegramAudioIdentity) {
        errors[identity] = error
    }

    func setDeferred(_ value: Bool, for identity: TelegramAudioIdentity) {
        if value { deferred.insert(identity) } else { deferred.remove(identity) }
    }

    func emitProgress(_ progress: DownloadProgress, for identity: TelegramAudioIdentity) {
        progressHandlers[identity]?(progress)
    }

    func observeAuthState() -> AsyncStream<TelegramAuthState> {
        AsyncStream { continuation in
            Task {
                continuation.yield(await self.authState)
                continuation.finish()
            }
        }
    }

    func submitPhone(_ phone: String) async throws {}
    func submitCode(_ code: String) async throws {}
    func submitPassword(_ password: String) async throws {}
    func logout() async throws {}
    func loadChats() async throws -> [TelegramChat] { [] }

    func loadAudioMessages(_ request: TelegramAudioPageRequest) async throws -> TelegramAudioPage {
        try TelegramAudioPage(chatID: request.chatID, messages: [], nextCursor: nil)
    }

    func downloadAudio(
        _ audio: TelegramAudio,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        downloaded.append(audio)
        activeCancellations.remove(audio.identity)
        startedContinuation.yield(audio.identity)
        progressHandlers[audio.identity] = progress
        progress(try! DownloadProgress(totalBytes: 4, completedBytes: 2))
        if let error = errors[audio.identity] { throw error }
        guard deferred.contains(audio.identity) else { return try makeSource(for: audio) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[audio.identity] = continuation
                if activeCancellations.contains(audio.identity) {
                    pending[audio.identity] = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { await self.cancelDownload(for: audio.identity) }
        }
    }

    func cancelDownload(for identity: TelegramAudioIdentity) async {
        cancelled.insert(identity)
        activeCancellations.insert(identity)
        pending.removeValue(forKey: identity)?.resume(throwing: CancellationError())
    }

    func completeDownload(for identity: TelegramAudioIdentity) async throws {
        let audio = try! TelegramAudio(
            identity: identity,
            fileID: Int32(identity.messageID),
            fileReference: "reference",
            duration: 123,
            fileSize: 4,
            mimeType: "audio/mpeg"
        )
        let url = try makeSource(for: audio)
        pending.removeValue(forKey: identity)?.resume(returning: url)
    }

    private func makeSource(for audio: TelegramAudio) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).download")
        try Data("audio".utf8).write(to: url)
        return url
    }
}

actor FakePlaybackBacking: PlaybackBacking {
    let events: AsyncStream<PlaybackBackingEvent>
    private let continuation: AsyncStream<PlaybackBackingEvent>.Continuation
    private var currentGeneration: UInt64 = 0
    private var storedPosition: TimeInterval = 0
    private var storedDuration: TimeInterval = 0
    private var automaticReady = true
    private var loadError: PlayerError?
    private var playError: PlayerError?
    private(set) var loadedURLs: [URL] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seekPositions: [TimeInterval] = []

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    var currentPosition: TimeInterval? { storedPosition }

    func setAutomaticReady(_ value: Bool) {
        automaticReady = value
    }

    func setLoadError(_ error: PlayerError?) {
        loadError = error
    }

    func setPlayError(_ error: PlayerError?) {
        playError = error
    }

    func load(url: URL, autoplay: Bool, generation: UInt64) async throws {
        currentGeneration = generation
        storedPosition = 0
        storedDuration = 100
        loadedURLs.append(url)
        if let loadError { throw loadError }
        if autoplay { try await play() }
        if automaticReady { emit(.ready(duration: storedDuration)) }
    }

    func play() async throws {
        if let playError { throw playError }
        playCount += 1
        storedDuration = 100
    }

    func pause() async throws {
        pauseCount += 1
    }

    func seek(to position: TimeInterval) async throws {
        storedPosition = position
        seekPositions.append(position)
    }

    func stop() async throws {
        currentGeneration += 1
        storedPosition = 0
        storedDuration = 0
    }

    func emitReady(duration: TimeInterval = 100) {
        storedDuration = duration
        emit(.ready(duration: duration))
    }

    func emitTime(position: TimeInterval, duration: TimeInterval? = nil) {
        storedPosition = position
        if let duration { storedDuration = duration }
        emit(.timeChanged(position: position, duration: duration))
    }

    func emitCompleted() {
        storedPosition = storedDuration
        emit(.completed)
    }

    func emitFailed(_ error: PlayerError) {
        emit(.failed(error))
    }

    private func emit(_ kind: PlaybackBackingEvent.Kind) {
        continuation.yield(PlaybackBackingEvent(generation: currentGeneration, kind: kind))
    }
}

func assertEqual<T: Equatable>(
    _ lhs: T,
    _ rhs: T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    XCTAssertEqual(lhs, rhs, file: file, line: line)
}

func assertNil<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    XCTAssertNil(value, file: file, line: line)
}

func assertNotNil<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    XCTAssertNotNil(value, file: file, line: line)
}

func assertTrue(
    _ value: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    XCTAssertTrue(value, file: file, line: line)
}

func assertDomainError(
    _ expected: DomainError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? DomainError, expected, file: file, line: line)
    }
}

func eventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping () async -> Bool
) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition did not become true", file: file, line: line)
    throw DomainError.library(.unavailable)
}
