import Foundation
import MusicCore

/// Owns cover-art files next to the audio library.
///
/// Artwork is optional: a missing or unreadable cover must never block an import, so
/// every failure here is reported to the caller, which treats it as "no artwork".
public actor ArtworkStore {
    public nonisolated let directory: URL

    /// Covers are small; anything larger is almost certainly not a thumbnail.
    private static let maximumBytes = 8 * 1024 * 1024
    private static let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    public init(directory: URL? = nil) throws {
        let base: URL
        if let directory {
            base = directory
        } else {
            base = try Self.defaultDirectory()
        }
        let resolved = base.standardizedFileURL
        guard resolved.isFileURL else { throw DomainError.library(.unavailable) }
        try FileManager.default.createDirectory(
            at: resolved,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.directory = resolved
    }

    public static func defaultDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DomainError.library(.unavailable)
        }
        return support
            .appendingPathComponent("MusicLibrary", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    /// Writes encoded image data and returns the stored file URL.
    public func store(data: Data, fileExtension: String = "jpg") throws -> URL {
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw DomainError.library(.writeFailed)
        }
        let suffix = Self.allowedExtensions.contains(fileExtension.lowercased())
            ? fileExtension.lowercased()
            : "jpg"
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw DomainError.library(.writeFailed)
        }
        return url
    }

    /// Copies a cover the source already wrote somewhere else.
    public func importFile(at sourceURL: URL) throws -> URL {
        guard sourceURL.isFileURL else { throw DomainError.library(.corruptData) }
        let data: Data
        do {
            let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw DomainError.library(.corruptData)
            }
            guard size <= Self.maximumBytes else { throw DomainError.library(.writeFailed) }
            data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch let error as DomainError {
            throw error
        } catch {
            throw DomainError.library(.corruptData)
        }
        return try store(data: data, fileExtension: sourceURL.pathExtension)
    }

    public func delete(at url: URL) {
        guard url.isFileURL,
              url.deletingLastPathComponent().standardizedFileURL == directory else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes covers no track references any more.
    public func cleanupOrphans(referencedBy referencedURLs: Set<URL>) {
        let referenced = Set(referencedURLs.map { $0.standardizedFileURL })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names {
            let url = directory.appendingPathComponent(name).standardizedFileURL
            if !referenced.contains(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
