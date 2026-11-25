import Foundation
import MusicCore
import XCTest
@testable import MusicLibrary

final class LibraryStoreTests: XCTestCase {
    func testTracksRoundTripOrderLookupDuplicatesAndDeletion() async throws {
        let container = try SwiftDataLibraryStore.makeContainer(inMemory: true)
        let store = SwiftDataLibraryStore(container: container)
        let first = TestSupport.track(messageID: 1, importedAt: Date(timeIntervalSince1970: 100))
        let second = TestSupport.track(messageID: 2, importedAt: Date(timeIntervalSince1970: 300))
        let third = TestSupport.track(messageID: 3, importedAt: Date(timeIntervalSince1970: 200))

        try await store.insertTrack(first)
        try await store.insertTrack(second)
        try await store.insertTrack(third)

        let tracks = try await store.tracks()
        XCTAssertEqual(tracks.map(\.id), [second.id, third.id, first.id])
        await assertEqual(try await store.track(id: second.id), second)
        await assertEqual(try await store.track(for: second.telegramIdentity), second)
        await assertNil(try await store.track(for: TestSupport.audio(messageID: 99).identity))

        let duplicate = TestSupport.track(messageID: 2)
        await assertDomainError(.duplicateTrack(duplicate.telegramIdentity)) {
            try await store.insertTrack(duplicate)
        }
        await assertEqual(try await store.tracks().count, 3)

        try await store.deleteTrack(id: third.id)
        await assertEqual(try await store.tracks().map(\.id), [second.id, first.id])
        await assertDomainError(.trackNotFound(third.id)) {
            try await store.track(id: third.id)
        }
    }

    func testTrackObserverEmitsInitialAndLaterSnapshots() async throws {
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        var iterator = store.observeTracks().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [])

        let track = TestSupport.track()
        try await store.insertTrack(track)
        let updated = await iterator.next()
        XCTAssertEqual(updated, [track])
    }

    func testCancelledObserversAreNotRetainedWhenRegistered() async throws {
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let (trackStream, trackContinuation) = AsyncStream<[Track]>.makeStream()
        let trackRead = Task {
            var iterator = trackStream.makeAsyncIterator()
            return await iterator.next()
        }
        trackRead.cancel()
        XCTAssertNil(await trackRead.value)
        await store.addTrackObserver(UUID(), continuation: trackContinuation)
        await assertEqual(await store.trackObserverCount, 0)

        let (jobStream, jobContinuation) = AsyncStream<[ImportJob]>.makeStream()
        let jobRead = Task {
            var iterator = jobStream.makeAsyncIterator()
            return await iterator.next()
        }
        jobRead.cancel()
        XCTAssertNil(await jobRead.value)
        await store.addJobObserver(UUID(), continuation: jobContinuation)
        await assertEqual(await store.jobObserverCount, 0)
    }

    func testJobsRoundTripNewestFirstAndObserveWholeReplacement() async throws {
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let older = try job(id: UUID(), messageID: 1, createdAt: 100)
        let newer = try job(id: UUID(), messageID: 2, createdAt: 200)
        try await store.saveImportJob(older)
        try await store.saveImportJob(newer)

        var iterator = store.observeImportJobs().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.id), [newer.id, older.id])

        let progress = try DownloadProgress(totalBytes: 10, completedBytes: 6)
        let importing = try older.items[0].transition(to: .importing, progress: progress)
        let active = try older.transition(to: .active, updatedAt: Date(timeIntervalSince1970: 101))
        let replaced = try ImportJob(
            id: active.id,
            sourceChat: active.sourceChat,
            items: [importing],
            status: active.status,
            createdAt: active.createdAt,
            updatedAt: Date(timeIntervalSince1970: 102)
        )
        try await store.saveImportJob(replaced)

        let observed = await iterator.next()
        XCTAssertEqual(observed?.first(where: { $0.id == older.id }), replaced)
        await assertEqual(try await store.importJob(id: older.id), replaced)
        await assertEqual(try await store.importJobs().map(\.id), [newer.id, older.id])
    }

    func testStaleJobSnapshotsCannotRegressTerminalStateOrProgress() async throws {
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let audio = TestSupport.audio()
        let lowerProgress = try DownloadProgress(totalBytes: 10, completedBytes: 2)
        let higherProgress = try DownloadProgress(totalBytes: 10, completedBytes: 8)
        let importing = try ImportItem(audio: audio, status: .importing, progress: lowerProgress)
        let active = try ImportJob(
            sourceChat: TestSupport.chat,
            items: [importing],
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try await store.saveImportJob(active)

        let progressedItem = try ImportItem(audio: audio, status: .importing, progress: higherProgress)
        let progressed = try ImportJob(
            id: active.id,
            sourceChat: active.sourceChat,
            items: [progressedItem],
            status: .active,
            createdAt: active.createdAt,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        try await store.saveImportJob(progressed)
        try await store.saveImportJob(active)
        await assertEqual(try await store.importJob(id: active.id), progressed)

        let trackID = UUID()
        let importedItem = try progressedItem.transition(
            to: .imported,
            progress: higherProgress,
            trackID: trackID
        )
        let activeWithImportedItem = try ImportJob(
            id: active.id,
            sourceChat: active.sourceChat,
            items: [importedItem],
            status: .active,
            createdAt: active.createdAt,
            updatedAt: Date(timeIntervalSince1970: 4)
        )
        try await store.saveImportJob(activeWithImportedItem)
        let itemRegression = try ImportJob(
            id: active.id,
            sourceChat: active.sourceChat,
            items: [importing],
            status: .active,
            createdAt: active.createdAt,
            updatedAt: Date(timeIntervalSince1970: 5)
        )
        try await store.saveImportJob(itemRegression)
        await assertEqual(try await store.importJob(id: active.id), activeWithImportedItem)

        let completed = try ImportJob(
            id: active.id,
            sourceChat: active.sourceChat,
            items: [importedItem],
            status: .completed,
            createdAt: active.createdAt,
            updatedAt: Date(timeIntervalSince1970: 6)
        )
        try await store.saveImportJob(completed)
        let aggregateRegression = try ImportJob(
            id: active.id,
            sourceChat: active.sourceChat,
            items: [importing],
            status: .active,
            createdAt: active.createdAt,
            updatedAt: Date(timeIntervalSince1970: 7)
        )
        try await store.saveImportJob(aggregateRegression)
        await assertEqual(try await store.importJob(id: active.id), completed)
    }

    func testJobSnapshotSurvivesPersistentStoreReopen() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library.store")
        let progress = try DownloadProgress(totalBytes: 10, completedBytes: 4)
        let item = try ImportItem(audio: TestSupport.audio(), status: .importing, progress: progress)
        let original = try ImportJob(
            sourceChat: TestSupport.chat,
            items: [item],
            status: .active,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )

        var store: SwiftDataLibraryStore? = SwiftDataLibraryStore(
            container: try SwiftDataLibraryStore.makeContainer(storageURL: url)
        )
        try await store?.saveImportJob(original)
        store = nil

        let reopened = SwiftDataLibraryStore(
            container: try SwiftDataLibraryStore.makeContainer(storageURL: url)
        )
        await assertEqual(try await reopened.importJob(id: original.id), original)
    }

    func testCorruptAndUnsupportedJobPayloadsAreRejected() async throws {
        let job = try job(id: UUID(), messageID: 1, createdAt: 1)
        let record = try PersistedImportJob(job: job)
        record.payload = Data("not-json".utf8)
        await assertDomainError(.library(.corruptData)) {
            _ = try record.value()
        }

        var json = try JSONSerialization.jsonObject(with: ImportJobSnapshot(job).encoded()) as! [String: Any]
        json["version"] = 2
        record.payload = try JSONSerialization.data(withJSONObject: json)
        await assertDomainError(.library(.corruptData)) {
            _ = try record.value()
        }

        json["version"] = 1
        json["status"] = "futureStatus"
        record.payload = try JSONSerialization.data(withJSONObject: json)
        await assertDomainError(.library(.corruptData)) {
            _ = try record.value()
        }
    }

    func testEveryDomainErrorRoundTripsThroughJobSnapshot() throws {
        let identity = TestSupport.audio().identity
        let trackID = UUID()
        let jobID = UUID()
        let errors: [DomainError] = [
            .invalidPhoneNumber, .invalidAuthenticationCode, .invalidPassword,
            .invalidAccountIdentifier, .invalidAccountName, .invalidAccountUsername,
            .invalidChatIdentifier, .invalidAudioIdentifier, .invalidChatTitle,
            .invalidFileIdentifier, .invalidFileReference, .invalidFileSize,
            .invalidMIMEType, .invalidDuration, .invalidAudioPageRequest, .invalidAudioPage,
            .invalidDownloadProgress, .invalidTrack, .invalidImportItem,
            .duplicateImportItem(identity), .invalidImportJob, .invalidPlaybackState,
            .invalidPlaybackQueue, .invalidStateTransition(from: "active", to: "paused"),
            .unauthenticated, .chatNotFound(42), .audioNotFound(identity),
            .duplicateTrack(identity), .trackNotFound(trackID), .importJobNotFound(jobID),
            .telegram(.notAuthorized), .telegram(.networkUnavailable), .telegram(.rateLimited),
            .telegram(.serviceUnavailable), .telegram(.invalidResponse), .telegram(.downloadFailed),
            .library(.unavailable), .library(.corruptData), .library(.writeFailed),
            .playback(.notReady), .playback(.fileUnavailable), .playback(.unsupportedFormat),
            .playback(.playbackFailed), .playback(.queueBoundary)
        ]

        for (index, error) in errors.enumerated() {
            let item = try ImportItem(
                audio: TestSupport.audio(messageID: Int64(index + 1)),
                status: .failed,
                error: error
            )
            let job = try ImportJob(sourceChat: TestSupport.chat, items: [item])
            let decoded = try JSONDecoder().decode(ImportJobSnapshot.self, from: ImportJobSnapshot(job).encoded())
            XCTAssertEqual(try decoded.job(), job, "Error \(index) did not round-trip")
        }
    }

    func testRetrySnapshotPreservesFinishedItemsAndProgress() async throws {
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let trackID = UUID()
        let progress = try DownloadProgress(totalBytes: 10, completedBytes: 3)
        let cancelled = try ImportItem(
            audio: TestSupport.audio(messageID: 1),
            status: .cancelled,
            progress: progress
        )
        let imported = try ImportItem(
            audio: TestSupport.audio(messageID: 2),
            status: .imported,
            trackID: trackID
        )
        let failed = try ImportItem(
            audio: TestSupport.audio(messageID: 3),
            status: .failed,
            error: .telegram(.downloadFailed)
        )
        let job = try ImportJob(
            sourceChat: TestSupport.chat,
            items: [cancelled, imported, failed],
            status: .partialFailure,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try await store.saveImportJob(job)
        let queued = try job.transition(to: .queued, updatedAt: Date(timeIntervalSince1970: 3))
        try await store.saveImportJob(queued)
        let restored = try await store.importJob(id: job.id)

        XCTAssertEqual(restored.status, .queued)
        XCTAssertEqual(restored.items[0].status, .waiting)
        XCTAssertEqual(restored.items[0].progress, progress)
        XCTAssertEqual(restored.items[1], imported)
        XCTAssertEqual(restored.items[2].status, .waiting)
        XCTAssertNil(restored.items[2].error)
    }

    private func job(id: UUID, messageID: Int64, createdAt: TimeInterval) throws -> ImportJob {
        try ImportJob(
            id: id,
            sourceChat: TestSupport.chat,
            items: [try ImportItem(audio: TestSupport.audio(messageID: messageID))],
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
