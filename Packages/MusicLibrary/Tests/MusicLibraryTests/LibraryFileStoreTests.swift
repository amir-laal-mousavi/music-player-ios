import Foundation
import MusicCore
import XCTest
@testable import MusicLibrary

final class LibraryFileStoreTests: XCTestCase {
    func testSystemAvailableCapacityIsAvailableForDirectory() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertGreaterThanOrEqual(try LibraryFileStore.systemAvailableCapacity(for: root), 0)
    }

    func testImportUsesUniqueGeneratedNamesAndPreservesSource() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("gateway-owned.download")
        try Data("audio".utf8).write(to: source)
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let store = try LibraryFileStore(directory: libraryRoot) { _ in 100 }
        let audio = TestSupport.audio(mimeType: "../../untrusted")

        let first = try await store.importDownloadedFile(for: audio, at: source)
        let second = try await store.importDownloadedFile(for: audio, at: source)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent(), libraryRoot.standardizedFileURL)
        XCTAssertEqual(first.pathExtension, "audio")
        XCTAssertFalse(first.lastPathComponent.contains("gateway-owned"))
        XCTAssertFalse(first.lastPathComponent.contains("untrusted"))
        XCTAssertEqual(try Data(contentsOf: first), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("audio".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path).count, 2)
    }

    func testImportConsumesGatewaySourceOnlyAfterDurableCopy() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("gateway.download")
        try Data("audio".utf8).write(to: source)
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let store = try LibraryFileStore(directory: libraryRoot) { _ in 100 }

        let imported = try await store.importDownloadedFile(
            for: TestSupport.audio(),
            at: source,
            removingSourceOnSuccess: true
        )

        XCTAssertEqual(try Data(contentsOf: imported), Data("audio".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let failedSource = root.appendingPathComponent("failed.download")
        try Data("audio".utf8).write(to: failedSource)
        let failing = try LibraryFileStore(directory: libraryRoot, availableCapacity: { _ in 100 }) { _ in
            throw DomainError.library(.writeFailed)
        }
        await assertDomainError(.library(.writeFailed)) {
            _ = try await failing.importDownloadedFile(
                for: TestSupport.audio(),
                at: failedSource,
                removingSourceOnSuccess: true
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedSource.path))
    }

    func testImportDoesNotDeleteASourceReplacedDuringCopy() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("gateway.download")
        let target = root.appendingPathComponent("keep")
        try Data("audio".utf8).write(to: source)
        try Data("keep".utf8).write(to: target)
        let store = try LibraryFileStore(
            directory: root.appendingPathComponent("Audio", isDirectory: true),
            availableCapacity: { _ in 100 }
        ) { _ in
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        }

        let imported = try await store.importDownloadedFile(
            for: TestSupport.audio(),
            at: source,
            removingSourceOnSuccess: true
        )

        XCTAssertEqual(try Data(contentsOf: imported), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCapacityFailurePreventsCopyAndLeavesNoPartial() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("audio".utf8).write(to: source)
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let store = try LibraryFileStore(directory: libraryRoot) { _ in 4 }

        await assertDomainError(.library(.writeFailed)) {
            _ = try await store.importDownloadedFile(for: TestSupport.audio(fileSize: 1), at: source)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testWriteFailureAndCancellationRemoveOnlyGeneratedPartial() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("audio".utf8).write(to: source)
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let unrelated = libraryRoot.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)

        let failing = try LibraryFileStore(directory: libraryRoot, availableCapacity: { _ in 100 }) { _ in
            throw DomainError.library(.writeFailed)
        }
        await assertDomainError(.library(.writeFailed)) {
            _ = try await failing.importDownloadedFile(for: TestSupport.audio(), at: source)
        }

        let cancelled = try LibraryFileStore(directory: libraryRoot, availableCapacity: { _ in 100 }) { _ in
            throw CancellationError()
        }
        do {
            _ = try await cancelled.importDownloadedFile(for: TestSupport.audio(), at: source)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path), ["keep.txt"])
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testSourceAndRootSymlinksAreRejected() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("audio".utf8).write(to: target)
        let sourceLink = root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: target)
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let store = try LibraryFileStore(directory: libraryRoot) { _ in 100 }

        await assertDomainError(.library(.writeFailed)) {
            _ = try await store.importDownloadedFile(for: TestSupport.audio(), at: sourceLink)
        }

        let realDirectory = root.appendingPathComponent("real-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let rootLink = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: realDirectory)
        do {
            _ = try LibraryFileStore(directory: rootLink)
            XCTFail("Expected symlink root rejection")
        } catch let error as DomainError {
            XCTAssertEqual(error, .library(.corruptData))
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("audio".utf8))
    }

    func testDeletionIsContainedAndIntendedFileOnly() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let store = try LibraryFileStore(directory: libraryRoot) { _ in 100 }
        let intended = libraryRoot.appendingPathComponent("intended.mp3")
        let other = libraryRoot.appendingPathComponent("other.mp3")
        let outside = root.appendingPathComponent("outside.mp3")
        try Data("intended".utf8).write(to: intended)
        try Data("other".utf8).write(to: other)
        try Data("outside".utf8).write(to: outside)
        let link = libraryRoot.appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        await assertDomainError(.library(.corruptData)) {
            try await store.deleteFile(at: outside)
        }
        await assertDomainError(.library(.corruptData)) {
            try await store.deleteFile(at: link)
        }
        try await store.deleteFile(at: intended)
        try await store.deleteFile(at: intended)

        XCTAssertFalse(FileManager.default.fileExists(atPath: intended.path))
        XCTAssertEqual(try Data(contentsOf: other), Data("other".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testOrphanCleanupKeepsReferencedOfflineFilesAndIgnoresOtherNames() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let store = try LibraryFileStore(directory: libraryRoot) { _ in 100 }
        let referenced = libraryRoot.appendingPathComponent("\(UUID().uuidString).mp3")
        let orphan = libraryRoot.appendingPathComponent("\(UUID().uuidString).flac")
        let partial = libraryRoot.appendingPathComponent(".\(UUID().uuidString).part")
        let unrelated = libraryRoot.appendingPathComponent("\(UUID().uuidString).mp3.backup")
        try Data("referenced".utf8).write(to: referenced)
        try Data("orphan".utf8).write(to: orphan)
        try Data("partial".utf8).write(to: partial)
        try Data("unrelated".utf8).write(to: unrelated)

        try await store.cleanupOrphanedFiles(referencedBy: [referenced])

        XCTAssertEqual(try Data(contentsOf: referenced), Data("referenced".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testCleanupRemovesOnlyValidHiddenUUIDPartials() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let store = try LibraryFileStore(directory: libraryRoot) { _ in 100 }
        let partial = libraryRoot.appendingPathComponent(".\(UUID().uuidString).part")
        let unrelated = libraryRoot.appendingPathComponent("keep.mp3")
        let malformed = libraryRoot.appendingPathComponent(".not-a-uuid.part")
        let outside = root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        let linkedPartial = libraryRoot.appendingPathComponent(".\(UUID().uuidString).part")
        try Data("partial".utf8).write(to: partial)
        try Data("keep".utf8).write(to: unrelated)
        try Data("malformed".utf8).write(to: malformed)
        try FileManager.default.createSymbolicLink(at: linkedPartial, withDestinationURL: outside)

        try await store.cleanupPartials()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: malformed), Data("malformed".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedPartial.path))
    }
}
