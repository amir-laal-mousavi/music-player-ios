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
        XCTAssertEqual(PlaybackState.idle.status, .idle)
        XCTAssertNoThrow(try PlaybackState(status: .loading, currentTrackID: trackID, duration: 120))
        XCTAssertNoThrow(try PlaybackState(status: .playing, currentTrackID: trackID, position: 30, duration: 120))
        XCTAssertNoThrow(try PlaybackState(status: .paused, currentTrackID: trackID, position: 30, duration: 120))
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
        XCTAssertThrowsError(try PlaybackState(status: .idle, currentTrackID: trackID))
    }
}
