import MusicCore
import XCTest
@testable import MusicPlayer

@MainActor
final class NowPlayingViewModelTests: XCTestCase {
    private func makeQueue() throws -> (player: FakePlayerEngine, tracks: [Track], model: NowPlayingViewModel) {
        let chat = try makeChat()
        let tracks = [
            try makeTrack(audio: try makeAudio(messageID: 103, title: "Night Drive"), chat: chat),
            try makeTrack(audio: try makeAudio(messageID: 102, title: "Morning Static"), chat: chat)
        ]
        let player = FakePlayerEngine()
        let model = NowPlayingViewModel(player: player, tracks: tracks, startingIndex: 0)
        return (player, tracks, model)
    }

    func testCannotSeekBeforePlaybackStarts() throws {
        let (_, _, model) = try makeQueue()

        XCTAssertEqual(model.state.status, .idle)
        XCTAssertFalse(model.canSeek)
        XCTAssertEqual(model.currentTrack?.title, "Night Drive")
    }

    func testCanSeekWhilePlaying() async throws {
        let (_, _, model) = try makeQueue()

        await model.start()
        defer { model.stop() }

        XCTAssertEqual(model.state.status, .playing)
        XCTAssertTrue(model.canSeek)
        XCTAssertTrue(model.canGoNext)
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertEqual(model.queueLabel, "Track 1 of 2")
    }

    func testCanSeekWhilePaused() async throws {
        let (_, _, model) = try makeQueue()
        await model.start()
        defer { model.stop() }

        await model.togglePlayback()

        XCTAssertEqual(model.state.status, .paused)
        XCTAssertTrue(model.canSeek)
        XCTAssertTrue(model.isPaused)
        XCTAssertFalse(model.isPlaying)
    }

    func testCommitSeekClampsToTrackDuration() async throws {
        let (player, tracks, model) = try makeQueue()
        await model.start()
        defer { model.stop() }

        model.scrubPosition = 500
        await model.commitSeek()

        let clampedToEnd = await player.lastSeek
        XCTAssertEqual(clampedToEnd ?? -1, tracks[0].duration, accuracy: 0.001)

        model.scrubPosition = -40
        await model.commitSeek()

        let clampedToStart = await player.lastSeek
        XCTAssertEqual(clampedToStart ?? -1, 0, accuracy: 0.001)
    }

    func testNextStopsAtQueueEnd() async throws {
        let (_, _, model) = try makeQueue()
        await model.start()
        defer { model.stop() }

        await model.next()
        XCTAssertEqual(model.currentTrack?.title, "Morning Static")
        XCTAssertFalse(model.canGoNext)
        XCTAssertTrue(model.canGoPrevious)

        await model.next()
        XCTAssertEqual(model.currentTrack?.title, "Morning Static")
    }
}
