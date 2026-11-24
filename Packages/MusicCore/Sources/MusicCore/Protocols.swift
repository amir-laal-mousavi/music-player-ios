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
    func observeState() -> AsyncStream<PlaybackState>
    func play(_ track: Track) async throws
    func pause() async throws
    /// Resumes paused or interrupted playback from its preserved position.
    func resume() async throws
    func stop() async throws
    func seek(to position: TimeInterval) async throws
}
