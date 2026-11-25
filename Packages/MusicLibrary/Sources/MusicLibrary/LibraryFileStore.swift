import Darwin
import Foundation
import MusicCore

public actor LibraryFileStore {
    public nonisolated let directory: URL

    private let availableCapacity: @Sendable (URL) throws -> Int64
    private let beforeWrite: @Sendable (URL) throws -> Void

    public init(
        directory: URL? = nil,
        availableCapacity: @escaping @Sendable (URL) throws -> Int64 = LibraryFileStore.systemAvailableCapacity
    ) throws {
        try self.init(
            resolvedDirectory: directory ?? Self.defaultDirectory(),
            availableCapacity: availableCapacity,
            beforeWrite: { _ in }
        )
    }

    init(
        directory: URL,
        availableCapacity: @escaping @Sendable (URL) throws -> Int64,
        beforeWrite: @escaping @Sendable (URL) throws -> Void
    ) throws {
        try self.init(
            resolvedDirectory: directory,
            availableCapacity: availableCapacity,
            beforeWrite: beforeWrite
        )
    }

    private init(
        resolvedDirectory: URL,
        availableCapacity: @escaping @Sendable (URL) throws -> Int64,
        beforeWrite: @escaping @Sendable (URL) throws -> Void
    ) throws {
        guard resolvedDirectory.isFileURL, !resolvedDirectory.path.utf8.contains(0) else {
            throw DomainError.library(.corruptData)
        }
        if FileManager.default.fileExists(atPath: resolvedDirectory.path) {
            let values = try resolvedDirectory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw DomainError.library(.corruptData)
            }
        } else {
            try FileManager.default.createDirectory(
                at: resolvedDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var values = try resolvedDirectory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw DomainError.library(.corruptData)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: resolvedDirectory.path
        )
        directory = resolvedDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.availableCapacity = availableCapacity
        self.beforeWrite = beforeWrite
    }

    public static func defaultDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DomainError.library(.unavailable)
        }
        return support.appendingPathComponent("MusicLibrary", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
    }

    public static func systemAvailableCapacity(for directory: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let capacity = attributes[.systemFreeSpace] as? NSNumber else {
            throw DomainError.library(.unavailable)
        }
        return capacity.int64Value
    }

    public func checkCapacity(bytes required: Int64?) async throws {
        let required = required ?? 1
        guard required >= 0 else { throw DomainError.invalidFileSize }
        let capacity: Int64
        do {
            capacity = try availableCapacity(directory)
        } catch let error as DomainError {
            throw error
        } catch {
            throw DomainError.library(.writeFailed)
        }
        guard capacity >= required else { throw DomainError.library(.writeFailed) }
    }

    public func importDownloadedFile(for audio: TelegramAudio, at sourceURL: URL) async throws -> URL {
        try await importDownloadedFile(for: audio, at: sourceURL, removingSourceOnSuccess: false)
    }

    func importDownloadedFile(
        for audio: TelegramAudio,
        at sourceURL: URL,
        removingSourceOnSuccess: Bool
    ) async throws -> URL {
        guard sourceURL.isFileURL, !sourceURL.path.utf8.contains(0) else {
            throw DomainError.library(.corruptData)
        }
        let sourceFD = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw DomainError.library(.writeFailed) }
        defer { close(sourceFD) }

        let sourceInfo = try fileInfo(sourceFD)
        guard S_ISREG(sourceInfo.st_mode), sourceInfo.st_nlink == 1, sourceInfo.st_size >= 0 else {
            throw DomainError.library(.corruptData)
        }
        let size = sourceInfo.st_size
        try await checkCapacity(bytes: size)

        let rootFD = try openRoot()
        defer { close(rootFD) }
        let id = UUID()
        let finalName = id.uuidString + "." + fileExtension(for: audio.mimeType)
        let partialName = "." + id.uuidString + ".part"
        let partialFD = openat(
            rootFD,
            partialName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard partialFD >= 0 else { throw DomainError.library(.writeFailed) }
        defer { close(partialFD) }

        var committed = false
        defer {
            if !committed { unlinkat(rootFD, partialName, 0) }
        }

        try beforeWrite(directory.appendingPathComponent(partialName, isDirectory: false))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let count = read(sourceFD, &buffer, min(buffer.count, Int(min(Int64(buffer.count), remaining))))
            if count <= 0 { throw DomainError.library(.writeFailed) }
            try writeAll(buffer: &buffer, count: count, to: partialFD)
            remaining -= Int64(count)
        }
        var extra = [UInt8](repeating: 0, count: 1)
        if read(sourceFD, &extra, 1) != 0 { throw DomainError.library(.writeFailed) }
        try Task.checkCancellation()
        guard fsync(partialFD) == 0 else { throw DomainError.library(.writeFailed) }
        guard renameatx_np(rootFD, partialName, rootFD, finalName, UInt32(RENAME_EXCL)) == 0 else {
            throw DomainError.library(.writeFailed)
        }
        guard fsync(rootFD) == 0 else {
            unlinkat(rootFD, finalName, 0)
            throw DomainError.library(.writeFailed)
        }
        committed = true
        if removingSourceOnSuccess {
            removeSourceIfUnchanged(sourceURL, sourceInfo: sourceInfo)
        }
        return directory.appendingPathComponent(finalName, isDirectory: false)
    }

    public func deleteFile(at url: URL) async throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw DomainError.library(.corruptData) }
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == directory,
              !standardized.lastPathComponent.isEmpty,
              standardized.lastPathComponent != ".", standardized.lastPathComponent != ".." else {
            throw DomainError.library(.corruptData)
        }

        let rootFD = try openRoot()
        defer { close(rootFD) }
        let name = standardized.lastPathComponent
        let info = try fstatat(rootFD, name, AT_SYMLINK_NOFOLLOW)
        guard info.st_mode != 0 else { return }
        guard S_ISREG(info.st_mode), info.st_nlink == 1 else {
            throw DomainError.library(.corruptData)
        }
        guard unlinkat(rootFD, name, 0) == 0 || errno == ENOENT else {
            throw DomainError.library(.writeFailed)
        }
    }

    public func cleanupPartials() async throws {
        try await removeGeneratedFiles(keeping: [], includeFinalFiles: false)
    }

    func cleanupOrphanedFiles(referencedBy referencedURLs: Set<URL>) async throws {
        let keeping = Set(
            referencedURLs
                .map(\.standardizedFileURL)
                .filter { $0.deletingLastPathComponent() == directory }
                .map(\.lastPathComponent)
        )
        try await removeGeneratedFiles(keeping: keeping, includeFinalFiles: true)
    }

    private func removeGeneratedFiles(keeping: Set<String>, includeFinalFiles: Bool) async throws {
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let listingFD = dup(rootFD)
        guard listingFD >= 0, let listing = fdopendir(listingFD) else {
            if listingFD >= 0 { close(listingFD) }
            throw DomainError.library(.unavailable)
        }
        defer { closedir(listing) }
        while let entry = readdir(listing) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            let isPartial = isPartialName(name)
            let isOrphan = includeFinalFiles && isFinalName(name) && !keeping.contains(name)
            guard isPartial || isOrphan else { continue }
            let info = try fstatat(rootFD, name, AT_SYMLINK_NOFOLLOW)
            guard info.st_mode != 0 else { continue }
            guard S_ISREG(info.st_mode), info.st_nlink == 1 else { continue }
            guard unlinkat(rootFD, name, 0) == 0 || errno == ENOENT else {
                throw DomainError.library(.writeFailed)
            }
        }
    }

    private func removeSourceIfUnchanged(_ sourceURL: URL, sourceInfo: stat) {
        // The library copy is durable; failure to remove the gateway's staged copy only wastes cache space.
        let parentFD = open(
            sourceURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentFD >= 0 else { return }
        defer { close(parentFD) }
        var current = stat()
        guard fstatat(parentFD, sourceURL.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == sourceInfo.st_dev, current.st_ino == sourceInfo.st_ino else { return }
        _ = unlinkat(parentFD, sourceURL.lastPathComponent, 0)
    }

    private func openRoot() throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DomainError.library(.writeFailed) }
        let info = try fileInfo(fd)
        guard S_ISDIR(info.st_mode) else {
            close(fd)
            throw DomainError.library(.corruptData)
        }
        return fd
    }

    private func fileInfo(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DomainError.library(.writeFailed) }
        return info
    }

    private func fstatat(_ directoryFD: Int32, _ name: String, _ flags: Int32) throws -> stat {
        var info = stat()
        guard fstatat(directoryFD, name, &info, flags) == 0 else {
            if errno == ENOENT {
                info.st_mode = 0
                return info
            }
            throw DomainError.library(.writeFailed)
        }
        return info
    }

    private func writeAll(buffer: inout [UInt8], count: Int, to fd: Int32) throws {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeMutableBytes { bytes in
                write(fd, bytes.baseAddress?.advanced(by: offset), count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw DomainError.library(.writeFailed) }
            offset += written
        }
    }

    private func fileExtension(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "video/mp4": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg", "application/ogg": return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/flac", "audio/x-flac": return "flac"
        default: return "audio"
        }
    }

    private func isPartialName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".part") else { return false }
        let value = String(name.dropFirst().dropLast(".part".count))
        return UUID(uuidString: value) != nil
    }

    private func isFinalName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return false }
        return ["mp3", "m4a", "aac", "ogg", "wav", "flac", "audio"].contains(String(parts[1]))
    }
}
