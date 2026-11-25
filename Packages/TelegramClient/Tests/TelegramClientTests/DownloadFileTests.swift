import Foundation
import MusicCore
import XCTest
@testable import TelegramClient

final class DownloadFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TelegramDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testStageAndPublishUseUniqueContainedNames() throws {
        let sourceRoot = root.appendingPathComponent("source")
        let destinationRoot = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("cache-file")
        let payload = Data("synthetic audio bytes".utf8)
        try payload.write(to: source)
        let directory = try SafeDownloadDirectory(directory: destinationRoot)
        let cancellation = DownloadCancellationToken()
        let first = try directory.stage(
            source: source,
            sourceRoot: sourceRoot,
            expectedSize: Int64(payload.count),
            fileExtension: "../../outside",
            cancellation: cancellation
        )
        let second = try directory.stage(
            source: source,
            sourceRoot: sourceRoot,
            expectedSize: Int64(payload.count),
            fileExtension: ".mp3",
            cancellation: cancellation
        )
        XCTAssertNotEqual(first.name, second.name)
        XCTAssertNotEqual(first.finalName, second.finalName)
        XCTAssertFalse(first.finalName.contains(".."))
        XCTAssertTrue(second.finalName.hasSuffix(".mp3"))
        let firstURL = try directory.publish(first, cancellation: cancellation)
        let secondURL = try directory.publish(second, cancellation: cancellation)
        XCTAssertEqual(firstURL.deletingLastPathComponent(), directory.url)
        XCTAssertEqual(try Data(contentsOf: firstURL), payload)
        XCTAssertEqual(try Data(contentsOf: secondURL), payload)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        XCTAssertEqual(Set(remaining), Set([firstURL.lastPathComponent, secondURL.lastPathComponent]))
    }

    func testPublicationDoesNotOverwriteAnExistingResult() async throws {
        let sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("cache-file")
        try Data("synthetic".utf8).write(to: source)
        let directory = try SafeDownloadDirectory(directory: root.appendingPathComponent("destination"))
        let cancellation = DownloadCancellationToken()
        let staged = try directory.stage(
            source: source,
            sourceRoot: sourceRoot,
            expectedSize: 9,
            fileExtension: nil,
            cancellation: cancellation
        )
        let published = try directory.publish(staged, cancellation: cancellation)
        await assertDomainError(.telegram(.downloadFailed)) {
            try directory.publish(staged, cancellation: cancellation)
        }
        staged.cleanup()
        XCTAssertEqual(try Data(contentsOf: published), Data("synthetic".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: published.deletingLastPathComponent().path), [published.lastPathComponent])
    }

    func testSourceOutsidePrivateRootIsRejected() async throws {
        let sourceRoot = root.appendingPathComponent("source")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        let link = sourceRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let directory = try SafeDownloadDirectory(directory: root.appendingPathComponent("destination"))
        await assertDomainError(.telegram(.downloadFailed)) {
            try directory.stage(
                source: link,
                sourceRoot: sourceRoot,
                expectedSize: 7,
                fileExtension: nil,
                cancellation: DownloadCancellationToken()
            )
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    func testSizeMismatchRemovesPartialStagingFile() async throws {
        let sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("cache-file")
        try Data("short".utf8).write(to: source)
        let directory = try SafeDownloadDirectory(directory: root.appendingPathComponent("destination"))
        await assertDomainError(.telegram(.downloadFailed)) {
            try directory.stage(
                source: source,
                sourceRoot: sourceRoot,
                expectedSize: 100,
                fileExtension: nil,
                cancellation: DownloadCancellationToken()
            )
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    func testCancellationDuringCopyRemovesPartialStagingFile() async throws {
        let sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("cache-file")
        try Data(repeating: 0x5A, count: 32 * 1024 * 1024).write(to: source)
        let directory = try SafeDownloadDirectory(directory: root.appendingPathComponent("destination"))
        let cancellation = DownloadCancellationToken()
        let task = Task {
            try directory.stage(
                source: source,
                sourceRoot: sourceRoot,
                expectedSize: 32 * 1024 * 1024,
                fileExtension: nil,
                cancellation: cancellation
            )
        }
        var observedPartial = false
        for _ in 0..<10_000 {
            if !(try FileManager.default.contentsOfDirectory(atPath: directory.url.path)).isEmpty {
                observedPartial = true
                cancellation.cancel()
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(observedPartial)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    func testCancelledPublicationLeavesNoFileAfterCallerCleanup() throws {
        let sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("cache-file")
        try Data("synthetic".utf8).write(to: source)
        let directory = try SafeDownloadDirectory(directory: root.appendingPathComponent("destination"))
        let cancellation = DownloadCancellationToken()
        let staged = try directory.stage(
            source: source,
            sourceRoot: sourceRoot,
            expectedSize: 9,
            fileExtension: nil,
            cancellation: cancellation
        )
        cancellation.cancel()
        do {
            _ = try directory.publish(staged, cancellation: cancellation)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            staged.cleanup()
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    func testRenamedDestinationRootIsNotPublished() async throws {
        let sourceRoot = root.appendingPathComponent("source")
        let destinationRoot = root.appendingPathComponent("destination")
        let movedRoot = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("cache-file")
        try Data("synthetic".utf8).write(to: source)
        let directory = try SafeDownloadDirectory(directory: destinationRoot)
        let cancellation = DownloadCancellationToken()
        let staged = try directory.stage(
            source: source,
            sourceRoot: sourceRoot,
            expectedSize: 9,
            fileExtension: nil,
            cancellation: cancellation
        )
        try FileManager.default.moveItem(at: destinationRoot, to: movedRoot)
        defer { try? FileManager.default.moveItem(at: movedRoot, to: destinationRoot) }
        await assertDomainError(.telegram(.downloadFailed)) {
            try directory.publish(staged, cancellation: cancellation)
        }
        staged.cleanup()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: movedRoot.path).isEmpty)
    }
}
