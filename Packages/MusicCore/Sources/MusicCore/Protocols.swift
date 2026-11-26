import Foundation

/// Chat and audio operations require an authenticated current account.
public protocol TelegramGateway: Sendable {
    var authState: TelegramAuthState { get async }
    /// The authenticated Telegram user, or nil when no account is active.
    var currentAccount: TelegramAccount? { get async }
    func observeAuthState() -> AsyncStream<TelegramAuthState>
    func submitPhone(_ phone: String) async throws
    func submitCode(_ code: String) async throws
    func submitPassword(_ password: String) async throws
    func logout() async throws
    func loadChats() async throws -> [TelegramChat]
    func loadAudioMessages(_ request: TelegramAudioPageRequest) async throws -> TelegramAudioPage
    func downloadAudio(
        _ audio: TelegramAudio,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL
    func cancelDownload(for identity: TelegramAudioIdentity) async
    /// Best-effort album cover download; returns nil when the source has none.
    func downloadThumbnail(_ thumbnail: TelegramThumbnail) async throws -> URL?
}

public extension TelegramGateway {
    func downloadThumbnail(_ thumbnail: TelegramThumbnail) async throws -> URL? { nil }
}

public protocol LibraryStore: Sendable {
    /// Returns tracks ordered by importedAt, newest first.
    func tracks() async throws -> [Track]
    func observeTracks() -> AsyncStream<[Track]>
    func track(id: Track.ID) async throws -> Track
    func track(for identity: TelegramAudioIdentity) async throws -> Track?
    /// Inserts one track and rejects an existing Telegram audio identity.
    func insertTrack(_ track: Track) async throws
    func deleteTrack(id: Track.ID) async throws
    /// Returns jobs ordered by createdAt, newest first.
    func importJobs() async throws -> [ImportJob]
    /// Emits the current jobs and every later saved snapshot.
    func observeImportJobs() -> AsyncStream<[ImportJob]>
    func importJob(id: ImportJob.ID) async throws -> ImportJob
    /// Replaces the whole persisted job so item progress survives process restarts.
    func saveImportJob(_ job: ImportJob) async throws
}

public protocol PlayerEngine: Sendable {
    var state: PlaybackState { get async }
    /// The transient queue, or nil when no queue is active.
    var queue: PlaybackQueue? { get async }
    func observeState() -> AsyncStream<PlaybackState>
    func play(_ track: Track) async throws
    /// Replaces playback with a queue and starts at the given valid index.
    func play(_ tracks: [Track], startingAt index: Int) async throws
    /// Starts the previous queue track at zero, or throws at the first track.
    func previous() async throws
    /// Starts the next queue track at zero, or throws at the last track.
    func next() async throws
    func pause() async throws
    /// Resumes paused or interrupted playback from its preserved position.
    func resume() async throws
    func stop() async throws
    func seek(to position: TimeInterval) async throws
    var repeatMode: RepeatMode { get async }
    var isShuffled: Bool { get async }
    func setRepeatMode(_ mode: RepeatMode) async
    func setShuffled(_ shuffled: Bool) async
}

public extension PlayerEngine {
    var repeatMode: RepeatMode { .off }
    var isShuffled: Bool { false }
    func setRepeatMode(_ mode: RepeatMode) async {}
    func setShuffled(_ shuffled: Bool) async {}
}
