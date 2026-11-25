@testable import MusicCore
import Foundation
import XCTest

final class ImportModelTests: XCTestCase {
    private let itemStatuses: [ImportItemStatus] = [
        .waiting, .importing, .imported, .duplicate, .failed, .cancelled
    ]

    private let allowedItemTransitions: [(ImportItemStatus, ImportItemStatus)] = [
        (.waiting, .importing),
        (.waiting, .duplicate),
        (.waiting, .failed),
        (.waiting, .cancelled),
        (.importing, .waiting),
        (.importing, .imported),
        (.importing, .duplicate),
        (.importing, .failed),
        (.importing, .cancelled),
        (.failed, .waiting),
        (.cancelled, .waiting)
    ]

    func testOnlyPendingImportItemsCanTransition() throws {
        let audio = try TestFixtures.audio()
        let trackID = UUID()
        for from in itemStatuses {
            let item = try ImportItem(
                audio: audio,
                status: from,
                progress: from == .importing ? try DownloadProgress(totalBytes: 10, completedBytes: 4) : nil,
                trackID: from == .imported || from == .duplicate ? trackID : nil,
                error: from == .failed ? .telegram(.downloadFailed) : nil
            )
            for to in itemStatuses {
                let isAllowed = allowedItemTransitions.contains { $0.0 == from && $0.1 == to }
                XCTAssertEqual(item.canTransition(to: to), isAllowed, "\(from) -> \(to)")
                if isAllowed {
                    let updated = try item.transition(
                        to: to,
                        trackID: to == .imported || to == .duplicate ? trackID : nil,
                        error: to == .failed ? .telegram(.downloadFailed) : nil
                    )
                    XCTAssertEqual(updated.status, to)
                    XCTAssertEqual(updated.audio, audio)
                } else {
                    XCTAssertThrowsError(try item.transition(to: to))
                }
            }
        }
    }

    func testImportItemRequiresTerminalDetails() throws {
        let audio = try TestFixtures.audio()
        XCTAssertThrowsError(try ImportItem(audio: audio, status: .imported)) { error in
            XCTAssertEqual(error as? DomainError, .invalidImportItem)
        }
        XCTAssertThrowsError(try ImportItem(audio: audio, status: .failed)) { error in
            XCTAssertEqual(error as? DomainError, .invalidImportItem)
        }
        XCTAssertThrowsError(try ImportItem(audio: audio, error: .unauthenticated)) { error in
            XCTAssertEqual(error as? DomainError, .invalidImportItem)
        }
        XCTAssertThrowsError(try ImportItem(audio: audio, trackID: UUID())) { error in
            XCTAssertEqual(error as? DomainError, .invalidImportItem)
        }
        XCTAssertNoThrow(try ImportItem(audio: audio, status: .duplicate, trackID: UUID()))
        XCTAssertThrowsError(try ImportItem(audio: audio, status: .duplicate)) { error in
            XCTAssertEqual(error as? DomainError, .invalidImportItem)
        }
    }

    func testRetryResetsOnlyUnfinishedImportItems() throws {
        let importedAudio = try TestFixtures.audio(messageID: 1)
        let duplicateAudio = try TestFixtures.audio(messageID: 2)
        let waitingAudio = try TestFixtures.audio(messageID: 3)
        let importingAudio = try TestFixtures.audio(messageID: 4)
        let failedAudio = try TestFixtures.audio(messageID: 5)
        let cancelledAudio = try TestFixtures.audio(messageID: 6)
        let importedTrackID = UUID()
        let duplicateTrackID = UUID()
        let progress = try DownloadProgress(totalBytes: 10, completedBytes: 4)
        let imported = try ImportItem(audio: importedAudio, status: .imported, trackID: importedTrackID)
        let duplicate = try ImportItem(audio: duplicateAudio, status: .duplicate, trackID: duplicateTrackID)
        let waiting = try ImportItem(audio: waitingAudio, progress: progress)
        let importing = try ImportItem(audio: importingAudio, status: .importing, progress: progress)
        let failed = try ImportItem(
            audio: failedAudio,
            status: .failed,
            progress: progress,
            error: .telegram(.networkUnavailable)
        )
        let cancelled = try ImportItem(audio: cancelledAudio, status: .cancelled, progress: progress)
        let items = [imported, duplicate, waiting, importing, failed, cancelled]
        let createdAt = Date(timeIntervalSince1970: 100)

        for status in [ImportJobStatus.partialFailure, .cancelled] {
            let job = try ImportJob(
                sourceChat: try TestFixtures.chat(),
                items: items,
                status: status,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            let retried = try job.transition(to: .queued, updatedAt: Date(timeIntervalSince1970: 200))
            XCTAssertEqual(retried.status, .queued)
            XCTAssertEqual(retried.items.map(\.id), items.map(\.id))
            XCTAssertEqual(Set(retried.items.map(\.id)).count, items.count)
            XCTAssertEqual(
                retried.items.map(\.status),
                [.imported, .duplicate, .waiting, .waiting, .waiting, .waiting]
            )
            XCTAssertEqual(retried.items[0], imported)
            XCTAssertEqual(retried.items[1], duplicate)
            XCTAssertEqual(retried.items[2], waiting)
            XCTAssertTrue(retried.items[3...].allSatisfy { $0.progress == progress })
            XCTAssertTrue(retried.items[3...].allSatisfy { $0.trackID == nil && $0.error == nil })
            XCTAssertEqual(retried.createdAt, createdAt)
        }
    }

    func testActiveJobCancellationRetryResetsStuckImportingItem() throws {
        let audio = try TestFixtures.audio()
        let progress = try DownloadProgress(totalBytes: 10, completedBytes: 4)
        let importing = try ImportItem(audio: audio, status: .importing, progress: progress)
        let job = try ImportJob(sourceChat: try TestFixtures.chat(), items: [importing], status: .active)

        let cancelled = try job.transition(to: .cancelled)
        let retried = try cancelled.transition(to: .queued)

        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.items.count, 1)
        XCTAssertEqual(retried.items[0].audio, audio)
        XCTAssertEqual(retried.items[0].status, .waiting)
        XCTAssertEqual(retried.items[0].progress, progress)
        XCTAssertNil(retried.items[0].trackID)
        XCTAssertNil(retried.items[0].error)
    }

    func testImportJobPersistsSourceAndValidatesOrdering() throws {
        let audio = try TestFixtures.audio()
        let sourceChat = try TestFixtures.chat(title: "Fixture channel", kind: .channel)
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        let job = try ImportJob(
            sourceChat: sourceChat,
            items: [try ImportItem(audio: audio)],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        XCTAssertEqual(job.sourceChat, sourceChat)
        XCTAssertEqual(job.chatID, TestFixtures.chatID)
        XCTAssertEqual(job.createdAt, createdAt)
        XCTAssertEqual(job.updatedAt, updatedAt)
        XCTAssertThrowsError(try ImportJob(
            sourceChat: sourceChat,
            items: [try ImportItem(audio: audio)],
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 99)
        ))
        XCTAssertThrowsError(try ImportJob(
            sourceChat: sourceChat,
            items: [try ImportItem(audio: audio)],
            createdAt: Date(timeIntervalSince1970: .nan),
            updatedAt: updatedAt
        ))
    }

    func testImportJobTransitionMatrixAndResumeSemantics() throws {
        let audio = try TestFixtures.audio()
        let item = try ImportItem(audio: audio)
        let statuses: [ImportJobStatus] = [
            .queued, .active, .pausing, .paused, .completed, .partialFailure, .cancelled, .waitingToResume
        ]
        let allowed: [(ImportJobStatus, ImportJobStatus)] = [
            (.queued, .active),
            (.queued, .cancelled),
            (.queued, .waitingToResume),
            (.active, .pausing),
            (.active, .paused),
            (.active, .completed),
            (.active, .partialFailure),
            (.active, .cancelled),
            (.active, .waitingToResume),
            (.pausing, .paused),
            (.pausing, .cancelled),
            (.paused, .active),
            (.paused, .cancelled),
            (.paused, .waitingToResume),
            (.waitingToResume, .queued),
            (.partialFailure, .queued),
            (.cancelled, .queued)
        ]
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        for from in statuses {
            let job = try ImportJob(
                sourceChat: try TestFixtures.chat(),
                items: [item],
                status: from,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            for to in statuses {
                let isAllowed = allowed.contains { $0.0 == from && $0.1 == to }
                XCTAssertEqual(job.canTransition(to: to), isAllowed, "\(from) -> \(to)")
                if isAllowed {
                    let updated = try job.transition(to: to, updatedAt: updatedAt)
                    XCTAssertEqual(updated.status, to)
                    XCTAssertEqual(updated.id, job.id)
                    XCTAssertEqual(updated.items, job.items)
                    XCTAssertEqual(updated.createdAt, createdAt)
                    XCTAssertEqual(updated.updatedAt, updatedAt)
                } else {
                    XCTAssertThrowsError(try job.transition(to: to))
                }
            }
        }

        let paused = try ImportJob(sourceChat: try TestFixtures.chat(), items: [item], status: .paused)
        let waiting = try paused.transition(to: .waitingToResume)
        let queued = try waiting.transition(to: .queued)
        XCTAssertEqual(try queued.transition(to: .active).status, .active)
    }

    func testImportJobRejectsDuplicateTelegramMessagesAndMixedChats() throws {
        let first = try TestFixtures.audio(title: "First title")
        let duplicate = try TestFixtures.audio(title: "Different title")
        let otherChat = try TestFixtures.audio(chatID: TestFixtures.chatID + 1)
        let firstItem = try ImportItem(audio: first)
        let duplicateItem = try ImportItem(audio: duplicate)
        let otherChatItem = try ImportItem(audio: otherChat)

        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertThrowsError(try ImportJob(sourceChat: try TestFixtures.chat(), items: [firstItem, duplicateItem])) { error in
            XCTAssertEqual(error as? DomainError, .duplicateImportItem(first.id))
        }
        XCTAssertThrowsError(try ImportJob(sourceChat: try TestFixtures.chat(), items: [firstItem, otherChatItem])) { error in
            XCTAssertEqual(error as? DomainError, .invalidImportJob)
        }
        XCTAssertNoThrow(try ImportJob(sourceChat: try TestFixtures.chat(), items: [firstItem], status: .queued))
    }
}
