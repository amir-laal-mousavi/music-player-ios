@testable import MusicCore
import Foundation
import XCTest

private actor TelegramGatewaySpy: TelegramGateway {
    private(set) var authState: TelegramAuthState = .unauthenticated
    private(set) var phone: String?
    private(set) var code: String?
    private(set) var password: String?
    private(set) var cancelledIdentity: TelegramAudioIdentity?

    nonisolated func observeAuthState() -> AsyncStream<TelegramAuthState> {
        AsyncStream { $0.finish() }
    }

    func submitPhone(_ phone: String) async throws {
        self.phone = try validatedPhoneNumber(phone)
        authState = try authState.transition(to: .waitingForCode)
    }

    func submitCode(_ code: String) async throws {
        self.code = try validatedAuthenticationCode(code)
        authState = try authState.transition(to: .waitingForPassword)
    }

    func submitPassword(_ password: String) async throws {
        self.password = try validatedPassword(password)
        authState = try authState.transition(to: .authenticated)
    }

    func logout() async throws {
        authState = try authState.transition(to: .loggingOut)
        authState = try authState.transition(to: .unauthenticated)
    }

    func loadChats() async throws -> [TelegramChat] {
        [try TelegramChat(id: TestFixtures.chatID, title: "Fixture chat")]
    }

    func loadAudioMessages(_ request: TelegramAudioPageRequest) async throws -> TelegramAudioPage {
        try TelegramAudioPage(
            chatID: request.chatID,
            messages: [
                try TestFixtures.audio(messageID: 10, chatID: request.chatID),
                try TestFixtures.audio(messageID: 11, chatID: request.chatID)
            ],
            nextCursor: 11
        )
    }

    func downloadAudio(
        _ audio: TelegramAudio,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        progress(try DownloadProgress(totalBytes: audio.fileSize, completedBytes: 512))
        return URL(fileURLWithPath: "/tmp/\(audio.id).mp3")
    }

    func cancelDownload(for identity: TelegramAudioIdentity) async {
        cancelledIdentity = identity
    }
}

private actor LibraryStoreSpy: LibraryStore {
    private var storedTracks: [Track] = []
    private var jobs: [ImportJob.ID: ImportJob] = [:]

    nonisolated func observeTracks() -> AsyncStream<[Track]> {
        AsyncStream { $0.finish() }
    }

    func tracks() async throws -> [Track] { storedTracks }

    func track(id: Track.ID) async throws -> Track {
        guard let track = storedTracks.first(where: { $0.id == id }) else {
            throw DomainError.trackNotFound(id)
        }
        return track
    }

    func track(for identity: TelegramAudioIdentity) async throws -> Track? {
        storedTracks.first { $0.telegramIdentity == identity }
    }

    func insertTrack(_ track: Track) async throws {
        guard !storedTracks.contains(where: { $0.telegramIdentity == track.telegramIdentity }) else {
            throw DomainError.duplicateTrack(track.telegramIdentity)
        }
        storedTracks.append(track)
    }

    func deleteTrack(id: Track.ID) async throws {
        guard let index = storedTracks.firstIndex(where: { $0.id == id }) else {
            throw DomainError.trackNotFound(id)
        }
        storedTracks.remove(at: index)
    }

    func importJobs() async throws -> [ImportJob] {
        Array(jobs.values)
    }

    func importJob(id: ImportJob.ID) async throws -> ImportJob {
        guard let job = jobs[id] else { throw DomainError.importJobNotFound(id) }
        return job
    }

    func saveImportJob(_ job: ImportJob) async throws {
        jobs[job.id] = job
    }
}

private actor PlayerEngineSpy: PlayerEngine {
    private(set) var state: PlaybackState = .idle

    nonisolated func observeState() -> AsyncStream<PlaybackState> {
        AsyncStream { $0.finish() }
    }

    func play(_ track: Track) async throws {
        state = try PlaybackState(status: .loading, currentTrackID: track.id, duration: track.duration)
        state = try PlaybackState(status: .playing, currentTrackID: track.id, duration: track.duration)
    }

    func pause() async throws {
        guard state.status == .playing, let trackID = state.currentTrackID else {
            throw DomainError.playback(.notReady)
        }
        state = try PlaybackState(
            status: .paused,
            currentTrackID: trackID,
            position: state.position,
            duration: state.duration
        )
    }

    func resume() async throws {
        guard state.status == .paused, let trackID = state.currentTrackID else {
            throw DomainError.playback(.notReady)
        }
        state = try PlaybackState(
            status: .playing,
            currentTrackID: trackID,
            position: state.position,
            duration: state.duration
        )
    }

    func stop() async throws {
        state = .idle
    }

    func seek(to position: TimeInterval) async throws {
        guard state.status == .playing || state.status == .paused, let trackID = state.currentTrackID else {
            throw DomainError.playback(.notReady)
        }
        state = try PlaybackState(
            status: state.status,
            currentTrackID: trackID,
            position: position,
            duration: state.duration
        )
    }
}

final class ProtocolConformanceTests: XCTestCase {
    func testGatewaySupportsAuthenticationPaginationDownloadAndCancellation() async throws {
        let gateway = TelegramGatewaySpy()
        try await gateway.submitPhone(" +1 555 0100 ")
        var state = await gateway.authState
        XCTAssertEqual(state, .waitingForCode)
        try await gateway.submitCode(" 12345 ")
        state = await gateway.authState
        XCTAssertEqual(state, .waitingForPassword)
        try await gateway.submitPassword("test-password")
        state = await gateway.authState
        XCTAssertEqual(state, .authenticated)

        let chats = try await gateway.loadChats()
        let request = try TelegramAudioPageRequest(chatID: TestFixtures.chatID, afterMessageID: 9, limit: 2)
        let page = try await gateway.loadAudioMessages(request)
        XCTAssertEqual(chats.map(\.id), [TestFixtures.chatID])
        XCTAssertEqual(page.messages.map(\.id), [10, 11])
        XCTAssertEqual(page.nextCursor, 11)
        let audio = try TestFixtures.audio(messageID: 10)
        let url = try await gateway.downloadAudio(audio) { progress in
            XCTAssertEqual(progress.completedBytes, 512)
        }
        XCTAssertTrue(url.isFileURL)
        await gateway.cancelDownload(for: audio.identity)
        let cancelledIdentity = await gateway.cancelledIdentity
        XCTAssertEqual(cancelledIdentity, audio.identity)

        try await gateway.logout()
        state = await gateway.authState
        XCTAssertEqual(state, .unauthenticated)
    }

    func testStoreSupportsUniqueTracksDeletionAndImportSnapshots() async throws {
        let store = LibraryStoreSpy()
        let audio = try TestFixtures.audio()
        let track = try TestFixtures.track(audio: audio)
        try await store.insertTrack(track)
        let tracks = try await store.tracks()
        XCTAssertEqual(tracks, [track])
        let found = try await store.track(for: audio.identity)
        XCTAssertEqual(found, track)

        do {
            try await store.insertTrack(try TestFixtures.track(audio: audio))
            XCTFail("Duplicate Telegram identities must be rejected")
        } catch {
            XCTAssertEqual(error as? DomainError, .duplicateTrack(audio.identity))
        }

        let item = try ImportItem(audio: audio)
        let job = try ImportJob(chatID: TestFixtures.chatID, items: [item])
        try await store.saveImportJob(job)
        let active = try job.transition(to: .active)
        try await store.saveImportJob(active)
        let persisted = try await store.importJob(id: job.id)
        XCTAssertEqual(persisted, active)
        let jobs = try await store.importJobs()
        XCTAssertEqual(jobs, [active])

        try await store.deleteTrack(id: track.id)
        let remaining = try await store.tracks()
        XCTAssertTrue(remaining.isEmpty)
        do {
            try await store.track(id: track.id)
            XCTFail("Deleted tracks must not be returned")
        } catch {
            XCTAssertEqual(error as? DomainError, .trackNotFound(track.id))
        }
    }

    func testPlayerSupportsLocalControlsAndState() async throws {
        let player = PlayerEngineSpy()
        let track = try TestFixtures.track(audio: TestFixtures.audio())
        try await player.play(track)
        var state = await player.state
        XCTAssertEqual(state.status, .playing)
        XCTAssertEqual(state.currentTrackID, track.id)
        try await player.seek(to: 30)
        try await player.pause()
        state = await player.state
        XCTAssertEqual(state.status, .paused)
        XCTAssertEqual(state.position, 30)
        try await player.resume()
        try await player.stop()
        state = await player.state
        XCTAssertEqual(state, .idle)

        do {
            try await player.seek(to: 1)
            XCTFail("Seeking without a current track must fail")
        } catch {
            XCTAssertEqual(error as? DomainError, .playback(.notReady))
        }
    }
}
