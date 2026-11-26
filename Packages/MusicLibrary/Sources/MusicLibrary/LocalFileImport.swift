import AVFoundation
import CryptoKit
import Foundation
import MusicCore
import UniformTypeIdentifiers

/// Metadata read from a local audio file before it enters the library.
public struct AudioFileMetadata: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let duration: TimeInterval
    public let fileSize: Int64?
    public let mimeType: String?

    public init(
        title: String,
        artist: String,
        duration: TimeInterval,
        fileSize: Int64?,
        mimeType: String?
    ) {
        self.title = title
        self.artist = artist
        self.duration = duration
        self.fileSize = fileSize
        self.mimeType = mimeType
    }
}

/// Reads playable-audio metadata for a file the app does not own yet.
public protocol AudioFileMetadataReading: Sendable {
    func metadata(forFileAt url: URL) async throws -> AudioFileMetadata
}

public enum LocalFileImportError: Error, Equatable, Sendable {
    case unreadableFile
    case emptyFile
    case unsupportedFormat
}

extension LocalFileImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The file could not be read."
        case .emptyFile:
            return "The file is empty."
        case .unsupportedFormat:
            return "This file is not audio the player can open."
        }
    }
}

/// AVFoundation-backed metadata reader used outside tests.
public struct AVFoundationAudioMetadataReader: AudioFileMetadataReading {
    public init() {}

    public func metadata(forFileAt url: URL) async throws -> AudioFileMetadata {
        let asset = AVURLAsset(url: url)
        let playable: Bool
        let duration: CMTime
        do {
            (playable, duration) = try await asset.load(.isPlayable, .duration)
        } catch {
            throw LocalFileImportError.unsupportedFormat
        }
        let seconds = duration.seconds
        guard playable, seconds.isFinite, seconds > 0 else {
            throw LocalFileImportError.unsupportedFormat
        }

        var title = ""
        var artist = ""
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue) {
                        title = value
                    }
                case .commonKeyArtist:
                    if let value = try? await item.load(.stringValue) {
                        artist = value
                    }
                default:
                    continue
                }
            }
        }

        let fileSize: Int64? = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)

        return AudioFileMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            duration: seconds,
            fileSize: fileSize,
            mimeType: Self.mimeType(for: url)
        )
    }

    static func mimeType(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return type.preferredMIMEType
    }
}

/// Local imports reuse the existing library pipeline by standing in for a chat.
///
/// `Track` requires a source chat and a `TelegramAudioIdentity`, so files picked from
/// the Files app or handed over by another app are attributed to this reserved,
/// virtual chat. Its identifier is far outside the range Telegram uses, and the
/// message identifier is derived from the file content, which makes re-importing
/// the same audio a duplicate even if it was renamed.
public enum LocalFileSource {
    public static let chatID: Int64 = .min
    public static let chatTitle = "Files"

    public static var chat: TelegramChat {
        // Valid by construction: the identifier is non-zero and the title is non-empty.
        try! TelegramChat(id: chatID, title: chatTitle, kind: .user)
    }

    public static func isLocal(_ identity: TelegramAudioIdentity) -> Bool {
        identity.chatID == chatID
    }

    /// A stable identity for the file's bytes, not its name.
    public static func identity(forFileAt url: URL) throws -> TelegramAudioIdentity {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LocalFileImportError.unreadableFile
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytes = 0
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw LocalFileImportError.unreadableFile
            }
            if chunk.isEmpty { break }
            totalBytes += chunk.count
            hasher.update(data: chunk)
        }
        guard totalBytes > 0 else { throw LocalFileImportError.emptyFile }

        var value: UInt64 = 0
        for byte in hasher.finalize().prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        value &= 0x7FFF_FFFF_FFFF_FFFF
        if value == 0 { value = 1 }
        return try TelegramAudioIdentity(chatID: chatID, messageID: Int64(value))
    }
}

public struct LocalFileImportResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case imported
        case duplicate
        case failed
    }

    public let fileName: String
    public let status: Status
    public let trackID: Track.ID?
    public let errorMessage: String?

    public init(fileName: String, status: Status, trackID: Track.ID?, errorMessage: String?) {
        self.fileName = fileName
        self.status = status
        self.trackID = trackID
        self.errorMessage = errorMessage
    }
}

public struct LocalFileImportSummary: Sendable, Equatable {
    public let results: [LocalFileImportResult]
    public let isCancelled: Bool

    public init(results: [LocalFileImportResult], isCancelled: Bool = false) {
        self.results = results
        self.isCancelled = isCancelled
    }

    public var importedCount: Int { results.filter { $0.status == .imported }.count }
    public var duplicateCount: Int { results.filter { $0.status == .duplicate }.count }
    public var failedResults: [LocalFileImportResult] { results.filter { $0.status == .failed } }
    public var failureCount: Int { failedResults.count }

    public var isEmpty: Bool { results.isEmpty }
}

public struct LocalFileImportProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentFileName: String?

    public init(completed: Int, total: Int, currentFileName: String?) {
        self.completed = completed
        self.total = total
        self.currentFileName = currentFileName
    }

    public var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// Copies audio files the app was handed into the library, deduplicating by content.
///
/// Unlike the Telegram import queue this is a short-lived operation: files are local,
/// so there is nothing to resume across launches. A file that was already copied stays
/// in the library even if the app is suspended mid-batch.
public actor LocalFileImporter {
    private let store: any LibraryStore
    private let fileStore: LibraryFileStore
    private let metadataReader: any AudioFileMetadataReading
    private let now: @Sendable () -> Date

    public init(
        store: any LibraryStore,
        fileStore: LibraryFileStore,
        metadataReader: any AudioFileMetadataReading = AVFoundationAudioMetadataReader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.fileStore = fileStore
        self.metadataReader = metadataReader
        self.now = now
    }

    public func importFiles(
        _ urls: [URL],
        progress: @escaping @Sendable (LocalFileImportProgress) -> Void = { _ in }
    ) async -> LocalFileImportSummary {
        let total = urls.count
        var results: [LocalFileImportResult] = []
        progress(LocalFileImportProgress(
            completed: 0,
            total: total,
            currentFileName: urls.first?.lastPathComponent
        ))

        for (index, url) in urls.enumerated() {
            if Task.isCancelled {
                return LocalFileImportSummary(results: results, isCancelled: true)
            }
            do {
                results.append(try await importFile(at: url))
            } catch {
                results.append(LocalFileImportResult(
                    fileName: url.lastPathComponent,
                    status: .failed,
                    trackID: nil,
                    errorMessage: Self.message(for: error)
                ))
            }
            let nextName = index + 1 < total ? urls[index + 1].lastPathComponent : nil
            progress(LocalFileImportProgress(
                completed: index + 1,
                total: total,
                currentFileName: nextName
            ))
        }

        return LocalFileImportSummary(results: results, isCancelled: Task.isCancelled)
    }

    private func importFile(at url: URL) async throws -> LocalFileImportResult {
        let fileName = url.lastPathComponent
        guard url.isFileURL else { throw LocalFileImportError.unreadableFile }

        // Files handed over by another app are security scoped; plain URLs ignore this.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let metadata = try await metadataReader.metadata(forFileAt: url)
        let identity = try LocalFileSource.identity(forFileAt: url)

        if let existing = try await store.track(for: identity) {
            return LocalFileImportResult(
                fileName: fileName,
                status: .duplicate,
                trackID: existing.id,
                errorMessage: nil
            )
        }

        let title = metadata.title.isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : metadata.title
        let audio = try TelegramAudio(
            identity: identity,
            fileID: 1,
            fileReference: "local:\(identity.messageID)",
            title: title,
            performer: metadata.artist,
            duration: metadata.duration,
            fileSize: metadata.fileSize,
            mimeType: metadata.mimeType
        )

        let localURL = try await fileStore.importDownloadedFile(for: audio, at: url)
        do {
            let track = try Track(
                telegramIdentity: identity,
                sourceChat: LocalFileSource.chat,
                title: audio.title,
                artist: audio.performer,
                duration: audio.duration,
                fileSize: audio.fileSize,
                importedAt: now(),
                localURL: localURL
            )
            try await store.insertTrack(track)
            return LocalFileImportResult(
                fileName: fileName,
                status: .imported,
                trackID: track.id,
                errorMessage: nil
            )
        } catch {
            try? await fileStore.deleteFile(at: localURL)
            if let domain = error as? DomainError,
               case .duplicateTrack = domain,
               let existing = try? await store.track(for: identity) {
                return LocalFileImportResult(
                    fileName: fileName,
                    status: .duplicate,
                    trackID: existing.id,
                    errorMessage: nil
                )
            }
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        if let local = error as? LocalFileImportError {
            return local.errorDescription ?? "The file could not be imported."
        }
        if let domain = error as? DomainError {
            switch domain {
            case .library(.writeFailed):
                return "There is not enough free space to copy this file."
            case .library(.unavailable), .library(.corruptData):
                return "The library storage is unavailable."
            case .invalidDuration, .invalidFileSize, .invalidMIMEType, .invalidTrack:
                return "The file's audio details are not valid."
            default:
                return "The file could not be imported."
            }
        }
        return "The file could not be imported."
    }
}
