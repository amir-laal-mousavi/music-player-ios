import Foundation
import MusicCore
import XCTest
@testable import MusicLibrary

final class PlayerEngineTests: XCTestCase {
    func testIdleRejectsControlsAndInvalidQueues() async throws {
        let (engine, _) = try makeEngine()
        await assertEqual(await engine.state, .idle)
        await assertNil(await engine.queue)
        await assertDomainError(.playback(.notReady)) { try await engine.previous() }
        await assertDomainError(.playback(.notReady)) { try await engine.next() }
        await assertDomainError(.playback(.notReady)) { try await engine.pause() }
        await assertDomainError(.playback(.notReady)) { try await engine.resume() }
        await assertDomainError(.playback(.notReady)) { try await engine.seek(to: 0) }
        await assertDomainError(.invalidPlaybackQueue) {
            try await engine.play([], startingAt: 0)
        }
        try await engine.stop()
        await assertEqual(await engine.state, .idle)
    }

    func testSingleTrackLoadingPauseResumeSeekAndStop() async throws {
        let backing = FakePlaybackBacking()
        await backing.setAutomaticReady(false)
        let engine = try makeEngine(backing: backing)
        let track = TestSupport.track()

        try await engine.play(track)
        await assertEqual(await engine.state.status, .loading)
        await assertEqual(await engine.state.currentTrackID, track.id)
        await assertEqual(await engine.state.duration, track.duration)
        await assertEqual(await engine.queue?.currentTrack, track)
        await assertEqual(await backing.loadedURLs, [track.localURL])

        await backing.emitReady(duration: 120)
        try await eventually { await engine.state.status == .playing }
        await backing.emitTime(position: 30, duration: 120)
        try await eventually { await engine.state.position == 30 }
        try await engine.pause()
        await assertEqual(await engine.state.status, .paused)
        await assertEqual(await engine.state.position, 30)
        try await engine.resume()
        await assertEqual(await engine.state.status, .playing)
        await assertEqual(await engine.state.position, 30)
        try await engine.seek(to: 45)
        await assertEqual(await engine.state.position, 45)
        await assertEqual(await backing.seekPositions, [45])
        try await engine.stop()
        await assertEqual(await engine.state, .idle)
        await assertNil(await engine.queue)
    }

    func testPauseDuringLoadingPreventsAutoplayAndRetainsDurationOnResume() async throws {
        let backing = FakePlaybackBacking()
        await backing.setAutomaticReady(false)
        let engine = try makeEngine(backing: backing)
        try await engine.play(TestSupport.track())
        try await engine.pause()
        await assertEqual(await engine.state.status, .paused)

        await backing.emitReady(duration: 90)
        try await eventually { await engine.state.duration == 90 }
        await assertEqual(await engine.state.status, .paused)
        await assertEqual(await backing.playCount, 0)
        try await engine.resume()
        await assertEqual(await engine.state.status, .playing)
        await assertEqual(await engine.state.duration, 90)
    }

    func testQueueNavigationAndBoundariesPreserveState() async throws {
        let engine = try makeEngine()
        let tracks = [
            TestSupport.track(messageID: 1),
            TestSupport.track(messageID: 2),
            TestSupport.track(messageID: 3)
        ]
        try await engine.play(tracks, startingAt: 1)
        try await eventually { await engine.state.status == .playing }
        await assertEqual(await engine.queue?.currentIndex, 1)

        try await engine.previous()
        await assertEqual(await engine.queue?.currentIndex, 0)
        let beforeBoundary = await engine.state
        await assertDomainError(.playback(.queueBoundary)) { try await engine.previous() }
        await assertEqual(await engine.state, beforeBoundary)
        await assertEqual(await engine.queue?.currentIndex, 0)

        try await engine.next()
        await assertEqual(await engine.queue?.currentIndex, 1)
        try await engine.next()
        await assertEqual(await engine.queue?.currentIndex, 2)
        await assertDomainError(.playback(.queueBoundary)) { try await engine.next() }
        await assertEqual(await engine.queue?.currentIndex, 2)
    }

    func testSeekRejectsInvalidPositionsWithoutChangingState() async throws {
        let engine = try makeEngine()
        try await engine.play(TestSupport.track())
        try await eventually { await engine.state.status == .playing }
        let original = await engine.state
        for position in [-1.0, 101.0, .nan, .infinity] {
            await assertDomainError(.playback(.playbackFailed)) {
                try await engine.seek(to: position)
            }
            await assertEqual(await engine.state, original)
        }
    }

    func testCompletionRetainsQueueAndNavigationStartsAtZero() async throws {
        let backing = FakePlaybackBacking()
        let engine = try makeEngine(backing: backing)
        let tracks = [TestSupport.track(messageID: 1), TestSupport.track(messageID: 2)]
        try await engine.play(tracks, startingAt: 0)
        try await eventually { await engine.state.status == .playing }
        await backing.emitTime(position: 80, duration: 100)
        try await eventually { await engine.state.position == 80 }
        await backing.emitCompleted()

        try await eventually { await engine.state.status == .completed }
        await assertEqual(await engine.state.position, 100)
        await assertEqual(await engine.queue?.currentIndex, 0)
        try await engine.next()
        await assertEqual(await engine.queue?.currentIndex, 1)
        try await eventually { await engine.state.status == .playing }
        await assertEqual(await engine.state.position, 0)
        try await engine.previous()
        await assertEqual(await engine.queue?.currentIndex, 0)
        await assertEqual(await engine.state.position, 0)
    }

    func testInterruptionsPreserveQueueAndPositionAndAllowResume() async throws {
        let backing = FakePlaybackBacking()
        let engine = try makeEngine(backing: backing)
        let tracks = [TestSupport.track(messageID: 1), TestSupport.track(messageID: 2)]
        try await engine.play(tracks, startingAt: 1)
        try await eventually { await engine.state.status == .playing }
        await backing.emitTime(position: 40, duration: 100)
        try await eventually { await engine.state.position == 40 }
        let queue = await engine.queue

        try await engine.interrupt(reason: .audioSession)
        await assertEqual(await engine.state.status, .interrupted(.audioSession))
        await assertEqual(await engine.state.position, 40)
        await assertEqual(await engine.queue, queue)
        try await engine.resume()
        await assertEqual(await engine.state.status, .playing)
        await assertEqual(await engine.state.position, 40)

        try await engine.interrupt(reason: .routeChange)
        await assertEqual(await engine.state.status, .interrupted(.routeChange))
        await assertEqual(await engine.queue, queue)
        try await engine.resume()
        await assertEqual(await engine.state.position, 40)
    }

    func testLoadingAndPlaybackFailuresMapToDomainErrors() async throws {
        let backing = FakePlaybackBacking()
        let engine = try makeEngine(backing: backing)
        await backing.setLoadError(.fileUnavailable)
        await assertDomainError(.playback(.fileUnavailable)) {
            try await engine.play(TestSupport.track())
        }
        await assertEqual(await engine.state.status, .failed)
        await assertEqual(await engine.state.error, .playback(.fileUnavailable))
        await assertNotNil(await engine.queue)

        await backing.setLoadError(nil)
        await backing.setAutomaticReady(false)
        let secondTrack = TestSupport.track(messageID: 2)
        try await engine.play(secondTrack)
        await backing.setPlayError(.playbackFailed)
        await backing.emitReady(duration: 100)
        try await eventually { await engine.state.status == .failed }
        await assertEqual(await engine.state.error, .playback(.playbackFailed))
        await assertEqual(await engine.state.currentTrackID, secondTrack.id)
    }

    func testStateObserverEmitsInitialAndControlSnapshots() async throws {
        let backing = FakePlaybackBacking()
        await backing.setAutomaticReady(false)
        let engine = try makeEngine(backing: backing)
        var iterator = engine.observeState().makeAsyncIterator()
        await assertEqual(await iterator.next(), .idle)

        try await engine.play(TestSupport.track())
        await assertEqual(await iterator.next()?.status, .loading)
        await backing.emitReady(duration: 100)
        await assertEqual(await iterator.next()?.status, .loading)
        await assertEqual(await iterator.next()?.status, .playing)
        try await engine.pause()
        await assertEqual(await iterator.next()?.status, .paused)
    }

    private func makeEngine(backing: FakePlaybackBacking = FakePlaybackBacking()) throws -> AVFoundationPlayerEngine {
        try AVFoundationPlayerEngine(backing: backing, configureAudioSession: {})
    }
}
