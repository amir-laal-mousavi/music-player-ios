import Foundation
import MusicCore
import XCTest
@testable import MusicLibrary

final class ImportCoordinatorTests: XCTestCase {
    func testSuccessfulImportPersistsMetadataJobAndPrivateFile() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([TestSupport.audio()], from: TestSupport.chat)
        let completed = try await coordinator.wait(for: queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.items.first?.status, .imported)
        let trackID = try XCTUnwrap(completed.items.first?.trackID)
        let track = try await store.track(id: trackID)
        XCTAssertEqual(track.telegramIdentity, TestSupport.audio().identity)
        XCTAssertEqual(track.sourceChat, TestSupport.chat)
        XCTAssertEqual(track.title, "Track 1")
        XCTAssertEqual(track.artist, "Artist")
        XCTAssertEqual(track.duration, 123)
        XCTAssertEqual(track.fileSize, 4)
        XCTAssertEqual(track.localURL.deletingLastPathComponent(), audioRoot.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: track.localURL), Data("audio".utf8))
        await assertEqual(await gateway.downloadCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".download") })
    }

    func testExistingIdentityIsDuplicateWithoutDownloading() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let existing = TestSupport.track()
        try await store.insertTrack(existing)
        let gateway = FakeTelegramGateway(directory: root)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([TestSupport.audio()], from: TestSupport.chat)
        let completed = try await coordinator.wait(for: queued.id)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.items.first?.status, .duplicate)
        XCTAssertEqual(completed.items.first?.trackID, existing.id)
        await assertEqual(await gateway.downloadCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path), [])
    }

    func testInsufficientCapacityFailsBeforeDownload() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 0 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([TestSupport.audio()], from: TestSupport.chat)
        let failed = try await coordinator.wait(for: queued.id)

        XCTAssertEqual(failed.status, .partialFailure)
        XCTAssertEqual(failed.items.first?.status, .failed)
        XCTAssertEqual(failed.items.first?.error, .library(.writeFailed))
        await assertEqual(await gateway.downloadCount, 0)
        await assertTrue(try await store.tracks().isEmpty)
    }

    func testWriteFailureCleansPartialAndRetryCompletes() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let failingFiles = try LibraryFileStore(
            directory: audioRoot,
            availableCapacity: { _ in 100 }
        ) { _ in throw DomainError.library(.writeFailed) }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: failingFiles)

        let queued = try await coordinator.enqueue([TestSupport.audio()], from: TestSupport.chat)
        let failed = try await coordinator.wait(for: queued.id)
        XCTAssertEqual(failed.status, .partialFailure)
        XCTAssertEqual(failed.items.first?.error, .library(.writeFailed))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path), [])

        let workingFiles = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let retrying = ImportCoordinator(gateway: gateway, store: store, fileStore: workingFiles)
        _ = try await retrying.retry(jobID: queued.id)
        let completed = try await retrying.wait(for: queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.items.first?.status, .imported)
        await assertEqual(try await store.tracks().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path).count, 1)
    }

    func testDownloadFailureWaitsAndResumesWhenConnectivityReturns() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setError(.networkUnavailable, for: audio.identity)
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        let waiting = try await coordinator.waitUntilWaiting(queued.id, in: store)
        XCTAssertEqual(waiting.status, .waitingToResume)
        XCTAssertEqual(waiting.items.first?.status, .waiting)

        await gateway.setError(nil, for: audio.identity)
        _ = try await coordinator.resume(jobID: queued.id)
        let completed = try await coordinator.wait(for: queued.id)
        XCTAssertEqual(completed.status, .completed)
    }

    func testWaitingJobCanBeCancelled() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setError(.networkUnavailable, for: audio.identity)
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        _ = try await coordinator.waitUntilWaiting(queued.id, in: store)
        let cancelled = try await coordinator.cancel(jobID: queued.id)

        await assertEqual(cancelled.status, .cancelled)
        await assertEqual(cancelled.items.first?.status, .cancelled)
        await assertEqual(try await store.importJob(id: queued.id), cancelled)
    }

    func testPauseCancelsActiveDownloadAndResumePreservesProgress() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setDeferred(true, for: audio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        await assertEqual(await starts.next(), audio.identity)
        try await eventually {
            let job = try? await store.importJob(id: queued.id)
            return job?.items.first?.progress?.completedBytes == 2
        }
        let paused = try await coordinator.pause(jobID: queued.id)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.items.first?.status, .waiting)
        XCTAssertEqual(paused.items.first?.progress?.completedBytes, 2)
        await assertTrue(await gateway.cancelledDownloads.contains(audio.identity))

        _ = try await coordinator.resume(jobID: queued.id)
        await assertEqual(await starts.next(), audio.identity)
        try await gateway.completeDownload(for: audio.identity)
        let completed = try await coordinator.wait(for: queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.items.first?.status, .imported)
    }

    func testOutOfOrderProgressCannotRegressImportingItem() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setDeferred(true, for: audio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        await assertEqual(await starts.next(), audio.identity)
        try await eventually {
            let job = try? await store.importJob(id: queued.id)
            return job?.items.first?.progress?.completedBytes == 2
        }
        var observations = store.observeImportJobs().makeAsyncIterator()
        await assertEqual(await observations.next()?.first?.items.first?.progress?.completedBytes, 2)

        let higherProgress = try DownloadProgress(totalBytes: 4, completedBytes: 4)
        await gateway.emitProgress(higherProgress, for: audio.identity)
        let higher = await observations.next()
        await assertEqual(higher?.first?.items.first?.progress, higherProgress)

        let lowerProgress = try DownloadProgress(totalBytes: 4, completedBytes: 1)
        await gateway.emitProgress(lowerProgress, for: audio.identity)
        let lower = await observations.next()
        await assertEqual(lower?.first?.items.first?.progress, higherProgress)

        try await gateway.completeDownload(for: audio.identity)
        let completed = try await coordinator.wait(for: queued.id)
        await assertEqual(completed.items.first?.status, .imported)
        await assertEqual(completed.items.first?.progress, higherProgress)
    }

    func testLateProgressAfterCancellationCannotMutateTerminalJob() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setDeferred(true, for: audio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        await assertEqual(await starts.next(), audio.identity)
        let cancelled = try await coordinator.cancel(jobID: queued.id)
        await assertEqual(cancelled.status, .cancelled)
        var observations = store.observeImportJobs().makeAsyncIterator()
        await assertEqual(await observations.next(), [cancelled])

        await gateway.emitProgress(try DownloadProgress(totalBytes: 4, completedBytes: 4), for: audio.identity)
        let lateSnapshot = await observations.next()
        await assertEqual(lateSnapshot, [cancelled])
        await assertEqual(lateSnapshot?.first?.items.first?.status, .cancelled)
        await assertEqual(lateSnapshot?.first?.items.first?.progress?.completedBytes, 2)
        await assertTrue(try await store.tracks().isEmpty)
        await assertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path), [])
    }

    func testCancelIsDurableAndRetryStartsSameJob() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setDeferred(true, for: audio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        await assertEqual(await starts.next(), audio.identity)
        let cancelled = try await coordinator.cancel(jobID: queued.id)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.items.first?.status, .cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path), [])

        await gateway.setDeferred(false, for: audio.identity)
        _ = try await coordinator.retry(jobID: queued.id)
        let completed = try await coordinator.wait(for: queued.id)
        XCTAssertEqual(completed.id, queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.items.first?.status, .imported)
    }

    func testDuplicateAppearingDuringDownloadRemovesNewCopy() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setDeferred(true, for: audio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        await assertEqual(await starts.next(), audio.identity)
        let existing = TestSupport.track()
        try await store.insertTrack(existing)
        try await gateway.completeDownload(for: audio.identity)
        let completed = try await coordinator.wait(for: queued.id)

        XCTAssertEqual(completed.items.first?.status, .duplicate)
        XCTAssertEqual(completed.items.first?.trackID, existing.id)
        await assertEqual(try await store.tracks().map(\.id), [existing.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path), [])
    }

    func testRecoverCleansPartialAndResumesDurableActiveJob() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let partial = audioRoot.appendingPathComponent(".\(UUID().uuidString).part")
        let orphan = audioRoot.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("partial".utf8).write(to: partial)
        try Data("orphan".utf8).write(to: orphan)
        let item = try ImportItem(audio: TestSupport.audio(), status: .importing)
        let interrupted = try ImportJob(sourceChat: TestSupport.chat, items: [item], status: .active)
        try await store.saveImportJob(interrupted)
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        try await coordinator.recover()
        let completed = try await coordinator.wait(for: interrupted.id)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path).count, 1)
    }

    func testRecoverRestartsDurableJobsOldestFirst() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let olderAudio = TestSupport.audio(messageID: 1)
        let newerAudio = TestSupport.audio(messageID: 2)
        await gateway.setDeferred(true, for: olderAudio.identity)
        await gateway.setDeferred(true, for: newerAudio.identity)
        let olderItem = try ImportItem(audio: olderAudio, status: .importing)
        let newerItem = try ImportItem(audio: newerAudio, status: .importing)
        let older = try ImportJob(
            sourceChat: TestSupport.chat,
            items: [olderItem],
            status: .active,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        let newer = try ImportJob(
            sourceChat: TestSupport.chat,
            items: [newerItem],
            status: .active,
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 201)
        )
        try await store.saveImportJob(older)
        try await store.saveImportJob(newer)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        try await coordinator.recover()

        let jobsByAudio = [olderAudio.identity: older, newerAudio.identity: newer]
        for expected in [olderAudio.identity, newerAudio.identity] {
            let next = await starts.next()
            let started = try XCTUnwrap(next)
            await assertEqual(started, expected)
            try await gateway.completeDownload(for: started)
            let completed = try await coordinator.wait(for: try XCTUnwrap(jobsByAudio[started]).id)
            await assertEqual(completed.status, .completed)
        }
    }

    func testJobsRunInEnqueueOrder() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let firstAudio = TestSupport.audio(messageID: 1)
        let secondAudio = TestSupport.audio(messageID: 2)
        await gateway.setDeferred(true, for: firstAudio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let first = try await coordinator.enqueue([firstAudio], from: TestSupport.chat)
        await assertEqual(await starts.next(), firstAudio.identity)
        let second = try await coordinator.enqueue([secondAudio], from: TestSupport.chat)
        for _ in 0..<100 { await Task.yield() }
        await assertEqual(await gateway.downloadCount, 1)

        try await gateway.completeDownload(for: firstAudio.identity)
        _ = try await coordinator.wait(for: first.id)
        await assertEqual(await starts.next(), secondAudio.identity)
        let completed = try await coordinator.wait(for: second.id)
        await assertEqual(completed.status, .completed)
        await assertEqual(try await store.tracks().count, 2)
    }

    func testConcurrentDuplicateJobsShareOneDownloadAndOneTrack() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setDeferred(true, for: audio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let first = try await coordinator.enqueue([audio], from: TestSupport.chat)
        await assertEqual(await starts.next(), audio.identity)
        let second = try await coordinator.enqueue([audio], from: TestSupport.chat)
        try await gateway.completeDownload(for: audio.identity)

        let imported = try await coordinator.wait(for: first.id)
        let duplicate = try await coordinator.wait(for: second.id)
        await assertEqual(imported.status, .completed)
        await assertEqual(duplicate.status, .completed)
        await assertEqual(duplicate.items.first?.status, .duplicate)
        await assertEqual(duplicate.items.first?.trackID, imported.items.first?.trackID)
        await assertEqual(await gateway.downloadCount, 1)
        await assertEqual(try await store.tracks().count, 1)
        await assertEqual(try FileManager.default.contentsOfDirectory(atPath: audioRoot.path).count, 1)
    }

    func testResumeWaitsForWaitingTaskToFinishBeforeRestarting() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let store = ControlledLibraryStore(base: base) { $0.status == .waitingToResume }
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setError(.networkUnavailable, for: audio.identity)
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)
        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        var gates = store.gatedSave.makeAsyncIterator()
        await assertNotNil(await gates.next())

        await gateway.setError(nil, for: audio.identity)
        let resumeTask = Task { try await coordinator.resume(jobID: queued.id) }
        for _ in 0..<100 { await Task.yield() }
        await store.releaseGatedSave()
        _ = try await resumeTask.value
        let completed = try await coordinator.wait(for: queued.id)
        await assertEqual(completed.status, .completed)
    }

    func testRetryWaitsForPartialFailureTaskToFinishBeforeRestarting() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let store = ControlledLibraryStore(base: base) { $0.status == .partialFailure }
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setError(.downloadFailed, for: audio.identity)
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)
        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        var gates = store.gatedSave.makeAsyncIterator()
        await assertNotNil(await gates.next())

        await gateway.setError(nil, for: audio.identity)
        let retryTask = Task { try await coordinator.retry(jobID: queued.id) }
        for _ in 0..<100 { await Task.yield() }
        await store.releaseGatedSave()
        _ = try await retryTask.value
        try await eventually {
            let job = try? await store.importJob(id: queued.id)
            return job?.status == .completed
        }
    }

    func testPauseFinishesDurableActiveJobWithoutAProductionTask() async throws {
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let progress = try DownloadProgress(totalBytes: 4, completedBytes: 2)
        let item = try ImportItem(audio: TestSupport.audio(), status: .importing, progress: progress)
        let active = try ImportJob(sourceChat: TestSupport.chat, items: [item], status: .active)
        try await store.saveImportJob(active)
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ImportCoordinator(
            gateway: FakeTelegramGateway(directory: root),
            store: store,
            fileStore: try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        )

        let paused = try await coordinator.pause(jobID: active.id)

        await assertEqual(paused.status, .paused)
        await assertEqual(paused.items.first?.status, .waiting)
        await assertEqual(paused.items.first?.progress, progress)
    }

    func testRecoverStopsActiveTaskBeforeCleaningAndRestartingIt() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audio = TestSupport.audio()
        await gateway.setDeferred(true, for: audio.identity)
        var starts = await gateway.startedDownloads.makeAsyncIterator()
        let files = try LibraryFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true)) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)
        let queued = try await coordinator.enqueue([audio], from: TestSupport.chat)
        await assertEqual(await starts.next(), audio.identity)
        await gateway.setDeferred(false, for: audio.identity)

        try await coordinator.recover()

        await assertEqual(await starts.next(), audio.identity)
        await assertEqual(await gateway.downloadCount, 2)
        await assertTrue(await gateway.cancelledDownloads.contains(audio.identity))
        let completed = try await coordinator.wait(for: queued.id)
        await assertEqual(completed.status, .completed)
    }

    func testMetadataDeleteFailureKeepsOfflineFile() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let store = ControlledLibraryStore(base: base)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let localURL = audioRoot.appendingPathComponent("track.mp3")
        try Data("audio".utf8).write(to: localURL)
        let track = TestSupport.track(localURL: localURL)
        try await store.insertTrack(track)
        await store.setDeleteFailure(.library(.writeFailed))
        let coordinator = ImportCoordinator(
            gateway: FakeTelegramGateway(directory: root),
            store: store,
            fileStore: files
        )

        await assertDomainError(.library(.writeFailed)) {
            try await coordinator.deleteTrack(id: track.id)
        }

        await assertEqual(try await store.track(id: track.id), track)
        XCTAssertEqual(try Data(contentsOf: localURL), Data("audio".utf8))
    }

    func testFailedJobRollbackKeepsFileWhenMetadataDeleteFails() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let store = ControlledLibraryStore(base: base)
        await store.setSaveFailure { job in
            job.status == .active && job.items.contains { $0.status == .imported }
        }
        await store.setDeleteFailure(.library(.writeFailed))
        let gateway = FakeTelegramGateway(directory: root)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)

        let queued = try await coordinator.enqueue([TestSupport.audio()], from: TestSupport.chat)
        let failed = try await coordinator.wait(for: queued.id)
        let track = try await store.track(for: TestSupport.audio().identity)

        await assertEqual(failed.status, .partialFailure)
        await assertNotNil(track)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(track).localURL), Data("audio".utf8))
    }

    func testDeleteImportedTrackRemovesMetadataAndOnlyItsFile() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
        let gateway = FakeTelegramGateway(directory: root)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let files = try LibraryFileStore(directory: audioRoot) { _ in 100 }
        let coordinator = ImportCoordinator(gateway: gateway, store: store, fileStore: files)
        let queued = try await coordinator.enqueue([TestSupport.audio()], from: TestSupport.chat)
        _ = try await coordinator.wait(for: queued.id)
        let tracks = try await store.tracks()
        let track = try XCTUnwrap(tracks.first)
        let outside = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)

        try await coordinator.deleteTrack(id: track.id)

        await assertTrue(try await store.tracks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: track.localURL.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }
}

private extension ImportCoordinator {
    func waitUntilWaiting(_ jobID: ImportJob.ID, in store: any LibraryStore) async throws -> ImportJob {
        try await eventually {
            guard let job = try? await store.importJob(id: jobID) else { return false }
            return job.status == .waitingToResume
        }
        return try await store.importJob(id: jobID)
    }
}
