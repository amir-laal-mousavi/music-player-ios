import Foundation
import MusicCore
import MusicLibrary
@testable import MusicPlayer

// MARK: - Factories

func makeChat(
    id: Int64 = 1001,
    title: String = "Focus",
    kind: TelegramChatKind = .group
) throws -> TelegramChat {
    try TelegramChat(id: id, title: title, kind: kind)
}

func makeAudio(
    chatID: Int64 = 1001,
    messageID: Int64,
    title: String = "Song",
    performer: String = "Artist",
    duration: TimeInterval = 2
) throws -> TelegramAudio {
    try TelegramAudio(
        identity: try TelegramAudioIdentity(chatID: chatID, messageID: messageID),
        fileID: 1,
        fileReference: "ref-\(messageID)",
        title: title,
        performer: performer,
        duration: duration,
        fileSize: nil,
        mimeType: "audio/wav"
    )
}

func makeTrack(
    audio: TelegramAudio,
    chat: TelegramChat,
    importedAt: Date = Date()
) throws -> Track {
    try Track(
        telegramIdentity: audio.identity,
        sourceChat: chat,
        title: audio.title,
        artist: audio.performer,
        duration: audio.duration,
        fileSize: audio.fileSize,
        importedAt: importedAt,
        localURL: URL(fileURLWithPath: "/tmp/musicplayer-tests/\(audio.messageID).wav")
    )
}

func makeFileStore() throws -> LibraryFileStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicPlayerTests-\(UUID().uuidString)", isDirectory: true)
    return try LibraryFileStore(directory: directory)
}

// MARK: - Library store

actor InMemoryLibraryStore: LibraryStore {
    private var trackList: [Track]
    private var jobList: [ImportJob] = []
    private var trackObservers: [UUID: AsyncStream<[Track]>.Continuation] = [:]
    private var jobObservers: [UUID: AsyncStream<[ImportJob]>.Continuation] = [:]

    init(tracks: [Track] = []) {
        trackList = tracks.sorted { $0.importedAt > $1.importedAt }
    }

    func tracks() async throws -> [Track] { trackList }

    nonisolated func observeTracks() -> AsyncStream<[Track]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { [weak self] in await self?.addTrackObserver(id, continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeTrackObserver(id) }
            }
        }
    }

    func track(id: Track.ID) async throws -> Track {
        guard let match = trackList.first(where: { $0.id == id }) else {
            throw DomainError.trackNotFound(id)
        }
        return match
    }

    func track(for identity: TelegramAudioIdentity) async throws -> Track? {
        trackList.first { $0.telegramIdentity == identity }
    }

    func insertTrack(_ track: Track) async throws {
        guard !trackList.contains(where: { $0.telegramIdentity == track.telegramIdentity }) else {
            throw DomainError.duplicateTrack(track.telegramIdentity)
        }
        trackList.insert(track, at: 0)
        await publishTracks()
    }

    func deleteTrack(id: Track.ID) async throws {
        guard trackList.contains(where: { $0.id == id }) else {
            throw DomainError.trackNotFound(id)
        }
        trackList.removeAll { $0.id == id }
        await publishTracks()
    }

    func importJobs() async throws -> [ImportJob] { jobList }

    nonisolated func observeImportJobs() -> AsyncStream<[ImportJob]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { [weak self] in await self?.addJobObserver(id, continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeJobObserver(id) }
            }
        }
    }

    func importJob(id: ImportJob.ID) async throws -> ImportJob {
        guard let match = jobList.first(where: { $0.id == id }) else {
            throw DomainError.importJobNotFound(id)
        }
        return match
    }

    func saveImportJob(_ job: ImportJob) async throws {
        if let index = jobList.firstIndex(where: { $0.id == job.id }) {
            jobList[index] = job
        } else {
            jobList.insert(job, at: 0)
        }
        await publishJobs()
    }

    private func publishTracks() async {
        for continuation in trackObservers.values { continuation.yield(trackList) }
    }

    private func publishJobs() async {
        for continuation in jobObservers.values { continuation.yield(jobList) }
    }

    private func addTrackObserver(_ id: UUID, _ continuation: AsyncStream<[Track]>.Continuation) {
        trackObservers[id] = continuation
        if case .terminated = continuation.yield(trackList) { trackObservers[id] = nil }
    }

    private func removeTrackObserver(_ id: UUID) {
        trackObservers[id] = nil
    }

    private func addJobObserver(_ id: UUID, _ continuation: AsyncStream<[ImportJob]>.Continuation) {
        jobObservers[id] = continuation
        if case .terminated = continuation.yield(jobList) { jobObservers[id] = nil }
    }

    private func removeJobObserver(_ id: UUID) {
        jobObservers[id] = nil
    }
}

// MARK: - Player

actor FakePlayerEngine: PlayerEngine {
    private(set) var state: PlaybackState
    private(set) var queue: PlaybackQueue?
    private(set) var lastSeek: TimeInterval?
    private(set) var playCallCount = 0
    private var observers: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]

    init(state: PlaybackState = .idle) {
        self.state = state
    }

    nonisolated func observeState() -> AsyncStream<PlaybackState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { [weak self] in await self?.addObserver(id, continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeObserver(id) }
            }
        }
    }

    func play(_ track: Track) async throws {
        try await play([track], startingAt: 0)
    }

    func play(_ tracks: [Track], startingAt index: Int) async throws {
        playCallCount += 1
        let nextQueue = try PlaybackQueue(tracks: tracks, currentIndex: index)
        queue = nextQueue
        publish(try PlaybackState(
            status: .playing,
            currentTrackID: nextQueue.currentTrack.id,
            position: 0,
            duration: nextQueue.currentTrack.duration
        ))
    }

    func previous() async throws {
        guard let queue else { throw DomainError.playback(.notReady) }
        try await play(queue.tracks, startingAt: queue.previous().currentIndex)
    }

    func next() async throws {
        guard let queue else { throw DomainError.playback(.notReady) }
        try await play(queue.tracks, startingAt: queue.next().currentIndex)
    }

    func pause() async throws {
        guard let trackID = state.currentTrackID else { throw DomainError.playback(.notReady) }
        publish(try PlaybackState(
            status: .paused,
            currentTrackID: trackID,
            position: state.position,
            duration: state.duration
        ))
    }

    func resume() async throws {
        guard let trackID = state.currentTrackID else { throw DomainError.playback(.notReady) }
        publish(try PlaybackState(
            status: .playing,
            currentTrackID: trackID,
            position: state.position,
            duration: state.duration
        ))
    }

    func stop() async throws {
        queue = nil
        publish(.idle)
    }

    func seek(to position: TimeInterval) async throws {
        guard let trackID = state.currentTrackID else { throw DomainError.playback(.notReady) }
        lastSeek = position
        publish(try PlaybackState(
            status: state.status == .completed ? .paused : state.status,
            currentTrackID: trackID,
            position: position,
            duration: state.duration
        ))
    }

    private func publish(_ next: PlaybackState) {
        state = next
        for continuation in observers.values { continuation.yield(next) }
    }

    private func addObserver(_ id: UUID, _ continuation: AsyncStream<PlaybackState>.Continuation) {
        observers[id] = continuation
        if case .terminated = continuation.yield(state) { observers[id] = nil }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}

// MARK: - Gateway

actor FakeTelegramGateway: TelegramGateway {
    private(set) var authState: TelegramAuthState
    private(set) var currentAccount: TelegramAccount?
    private(set) var requestedPageCursors: [TelegramAudio.MessageID?] = []

    private let chats: [TelegramChat]
    private let audios: [TelegramChat.ID: [TelegramAudio]]
    private var authObservers: [UUID: AsyncStream<TelegramAuthState>.Continuation] = [:]

    init(
        authState: TelegramAuthState = .authenticated,
        chats: [TelegramChat] = [],
        audios: [TelegramAudio] = []
    ) {
        self.authState = authState
        self.chats = chats
        var grouped: [TelegramChat.ID: [TelegramAudio]] = [:]
        for audio in audios {
            grouped[audio.chatID, default: []].append(audio)
        }
        self.audios = grouped.mapValues { $0.sorted { $0.messageID > $1.messageID } }
        currentAccount = nil
    }

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
        transition(to: .unauthenticated)
    }

    func loadChats() async throws -> [TelegramChat] { chats }

    func loadAudioMessages(_ request: TelegramAudioPageRequest) async throws -> TelegramAudioPage {
        requestedPageCursors.append(request.beforeMessageID)
        let all = audios[request.chatID] ?? []
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-download-\(audio.chatID)-\(audio.messageID).wav")
        try Data(repeating: 0, count: 512).write(to: url, options: .atomic)
        return url
    }

    func cancelDownload(for identity: TelegramAudioIdentity) async {}

    private func transition(to next: TelegramAuthState) {
        authState = next
        for continuation in authObservers.values { continuation.yield(next) }
    }

    private func addAuthObserver(_ id: UUID, _ continuation: AsyncStream<TelegramAuthState>.Continuation) {
        authObservers[id] = continuation
        if case .terminated = continuation.yield(authState) { authObservers[id] = nil }
    }

    private func removeAuthObserver(_ id: UUID) {
        authObservers[id] = nil
    }
}
