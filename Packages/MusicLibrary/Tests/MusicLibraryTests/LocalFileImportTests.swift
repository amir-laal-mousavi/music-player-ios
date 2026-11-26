import Foundation
import MusicCore
import XCTest
@testable import MusicLibrary

final class LocalFileImportTests: XCTestCase {
    func testImportCopiesAudioIntoLibraryAndRecordsFilesSource() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.mp3")
        try Data("audio-bytes".utf8).write(to: source)

        let store = try makeStore()
        let fileStore = try LibraryFileStore(directory: root.appendingPathComponent("Audio"))
        let importer = LocalFileImporter(
            store: store,
            fileStore: fileStore,
            metadataReader: FakeMetadataReader()
        )

        let summary = await importer.importFiles([source])

        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertFalse(summary.isCancelled)

        let tracks = try await store.tracks()
        await assertEqual(tracks.count, 1)
        await assertEqual(tracks[0].title, "Song")
        await assertEqual(tracks[0].artist, "Artist")
        await assertEqual(tracks[0].sourceChat.id, LocalFileSource.chatID)
        await assertEqual(tracks[0].sourceChat.title, LocalFileSource.chatTitle)
        await assertTrue(LocalFileSource.isLocal(tracks[0].telegramIdentity))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracks[0].localURL.path))
        await assertEqual(tracks[0].localURL.pathExtension, "mp3")
    }

    func testReimportingSameFileIsDuplicate() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.mp3")
        try Data("audio-bytes".utf8).write(to: source)

        let store = try makeStore()
        let fileStore = try LibraryFileStore(directory: root.appendingPathComponent("Audio"))
        let importer = LocalFileImporter(
            store: store,
            fileStore: fileStore,
            metadataReader: FakeMetadataReader()
        )

        _ = await importer.importFiles([source])
        let second = await importer.importFiles([source])

        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.duplicateCount, 1)
        await assertEqual(try await store.tracks().count, 1)
    }

    func testRenamedCopyOfSameContentIsDuplicate() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.mp3")
        let renamed = root.appendingPathComponent("different-name.mp3")
        try Data("audio-bytes".utf8).write(to: source)
        try FileManager.default.copyItem(at: source, to: renamed)

        let store = try makeStore()
        let fileStore = try LibraryFileStore(directory: root.appendingPathComponent("Audio"))
        let importer = LocalFileImporter(
            store: store,
            fileStore: fileStore,
            metadataReader: FakeMetadataReader()
        )

        _ = await importer.importFiles([source])
        let second = await importer.importFiles([renamed])

        XCTAssertEqual(second.duplicateCount, 1)
        XCTAssertEqual(second.results.first?.fileName, "different-name.mp3")
    }

    func testEmptyFileReportsFailureAndAddsNothing() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("empty.mp3")
        try Data().write(to: source)

        let store = try makeStore()
        let fileStore = try LibraryFileStore(directory: root.appendingPathComponent("Audio"))
        let importer = LocalFileImporter(
            store: store,
            fileStore: fileStore,
            metadataReader: FakeMetadataReader()
        )

        let summary = await importer.importFiles([source])

        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertEqual(summary.results.first?.errorMessage, "The file is empty.")
        await assertEqual(try await store.tracks().count, 0)
    }

    func testUnsupportedFormatReportsFailure() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: source)

        let store = try makeStore()
        let fileStore = try LibraryFileStore(directory: root.appendingPathComponent("Audio"))
        let importer = LocalFileImporter(
            store: store,
            fileStore: fileStore,
            metadataReader: FakeMetadataReader(failure: .unsupportedFormat)
        )

        let summary = await importer.importFiles([source])

        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertEqual(summary.results.first?.errorMessage, "This file is not audio the player can open.")
        await assertEqual(try await store.tracks().count, 0)
    }

    func testUntitledFileFallsBackToFileName() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Live at home.mp3")
        try Data("audio-bytes".utf8).write(to: source)

        let store = try makeStore()
        let fileStore = try LibraryFileStore(directory: root.appendingPathComponent("Audio"))
        let importer = LocalFileImporter(
            store: store,
            fileStore: fileStore,
            metadataReader: FakeMetadataReader(title: "")
        )

        _ = await importer.importFiles([source])

        await assertEqual(try await store.tracks().first?.title, "Live at home")
    }

    // MARK: - Helpers

    private func makeStore() throws -> SwiftDataLibraryStore {
        SwiftDataLibraryStore(container: try SwiftDataLibraryStore.makeContainer(inMemory: true))
    }
}

private struct FakeMetadataReader: AudioFileMetadataReading {
    var title = "Song"
    var artist = "Artist"
    var duration: TimeInterval = 120
    var fileSize: Int64? = 11
    var mimeType: String? = "audio/mpeg"
    var failure: LocalFileImportError?

    func metadata(forFileAt url: URL) async throws -> AudioFileMetadata {
        if let failure { throw failure }
        return AudioFileMetadata(
            title: title,
            artist: artist,
            duration: duration,
            fileSize: fileSize,
            mimeType: mimeType
        )
    }
}
