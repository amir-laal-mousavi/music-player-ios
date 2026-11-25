@testable import MusicCore
import Foundation
import XCTest

final class ProgressAndPlaybackTests: XCTestCase {
    func testDownloadProgressBounds() throws {
        let unknown = try DownloadProgress(totalBytes: nil, completedBytes: 500)
        XCTAssertNil(unknown.totalBytes)
        XCTAssertNil(unknown.fractionCompleted)
        let half = try DownloadProgress(totalBytes: 1_000, completedBytes: 500)
        XCTAssertEqual(half.fractionCompleted, 0.5)
        let empty = try DownloadProgress(totalBytes: 0, completedBytes: 0)
        XCTAssertEqual(empty.completedBytes, 0)
        XCTAssertNil(empty.fractionCompleted)
        let complete = try DownloadProgress(totalBytes: 10, completedBytes: 10)
        XCTAssertEqual(complete.fractionCompleted, 1)

        XCTAssertThrowsError(try DownloadProgress(totalBytes: -1, completedBytes: 0)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDownloadProgress)
        }
        XCTAssertThrowsError(try DownloadProgress(totalBytes: nil, completedBytes: -1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDownloadProgress)
        }
        XCTAssertThrowsError(try DownloadProgress(totalBytes: 10, completedBytes: 11)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDownloadProgress)
        }
        XCTAssertThrowsError(try DownloadProgress(totalBytes: 0, completedBytes: 1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDownloadProgress)
        }
    }

    func testPlaybackStateValidation() throws {
        let trackID = UUID()
        XCTAssertEqual(PlaybackState.idle, try PlaybackState(status: .idle))
        XCTAssertEqual(PlaybackState.idle.status, .idle)
        XCTAssertNoThrow(try PlaybackState(status: .loading, currentTrackID: trackID, duration: 120))
        XCTAssertNoThrow(try PlaybackState(status: .playing, currentTrackID: trackID, position: 30, duration: 120))
        XCTAssertNoThrow(try PlaybackState(status: .paused, currentTrackID: trackID, position: 30, duration: 120))
        XCTAssertNoThrow(try PlaybackState(
            status: .interrupted(.audioSession),
            currentTrackID: trackID,
            position: 30,
            duration: 120
        ))
        XCTAssertNoThrow(try PlaybackState(
            status: .interrupted(.routeChange),
            currentTrackID: trackID,
            position: 45,
            duration: 120
        ))
        XCTAssertNoThrow(try PlaybackState(status: .completed, currentTrackID: trackID, position: 120, duration: 120))
        XCTAssertNoThrow(try PlaybackState(status: .failed, currentTrackID: trackID, error: .playback(.fileUnavailable)))

        XCTAssertThrowsError(try PlaybackState(status: .playing, currentTrackID: trackID, position: -1, duration: 120))
        XCTAssertThrowsError(try PlaybackState(status: .playing, currentTrackID: trackID, position: 121, duration: 120))
        XCTAssertThrowsError(try PlaybackState(status: .playing, currentTrackID: trackID, position: .nan, duration: 120))
        XCTAssertThrowsError(try PlaybackState(status: .playing, currentTrackID: trackID, duration: .infinity))
        XCTAssertThrowsError(try PlaybackState(status: .playing, position: 0, duration: 120))
        XCTAssertThrowsError(try PlaybackState(status: .loading, currentTrackID: trackID, position: 1, duration: 120))
        XCTAssertThrowsError(try PlaybackState(status: .completed, currentTrackID: trackID, position: 119, duration: 120))
        XCTAssertThrowsError(try PlaybackState(status: .failed, currentTrackID: trackID))
        XCTAssertThrowsError(try PlaybackState(status: .paused, currentTrackID: trackID, error: .playback(.notReady)))
        XCTAssertThrowsError(try PlaybackState(
            status: .interrupted(.audioSession),
            position: 30,
            duration: 120
        ))
        XCTAssertThrowsError(try PlaybackState(
            status: .interrupted(.routeChange),
            currentTrackID: trackID,
            position: 30,
            duration: 120,
            error: .library(.unavailable)
        ))
        XCTAssertThrowsError(try PlaybackState(status: .idle, currentTrackID: trackID))
    }

    func testPlaybackQueueValidationAndMovement() throws {
        let tracks = try [10, 11, 12].map { messageID in
            try TestFixtures.track(
                audio: TestFixtures.audio(messageID: Int64(messageID))
            )
        }
        let queue = try PlaybackQueue(tracks: tracks, currentIndex: 1)
        XCTAssertEqual(queue.tracks, tracks)
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.currentTrack, tracks[1])
        XCTAssertTrue(queue.hasPrevious)
        XCTAssertTrue(queue.hasNext)
        let firstQueue = try queue.previous()
        XCTAssertEqual(firstQueue.currentTrack, tracks[0])
        XCTAssertFalse(firstQueue.hasPrevious)
        XCTAssertThrowsError(try firstQueue.previous()) { error in
            XCTAssertEqual(error as? DomainError, .playback(.queueBoundary))
        }
        let lastQueue = try queue.next()
        XCTAssertEqual(lastQueue.currentTrack, tracks[2])
        XCTAssertFalse(lastQueue.hasNext)
        XCTAssertThrowsError(try lastQueue.next()) { error in
            XCTAssertEqual(error as? DomainError, .playback(.queueBoundary))
        }

        XCTAssertThrowsError(try PlaybackQueue(tracks: [])) { error in
            XCTAssertEqual(error as? DomainError, .invalidPlaybackQueue)
        }
        XCTAssertThrowsError(try PlaybackQueue(tracks: [tracks[0], tracks[0]])) { error in
            XCTAssertEqual(error as? DomainError, .invalidPlaybackQueue)
        }
        XCTAssertThrowsError(try PlaybackQueue(tracks: tracks, currentIndex: -1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidPlaybackQueue)
        }
        XCTAssertThrowsError(try PlaybackQueue(tracks: tracks, currentIndex: tracks.count)) { error in
            XCTAssertEqual(error as? DomainError, .invalidPlaybackQueue)
        }
    }
}
