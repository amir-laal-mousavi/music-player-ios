import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

internal final class DownloadCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        return try body()
    }
}

internal struct StagedDownload: Sendable {
    let directory: SafeDownloadDirectory
    let name: String
    let finalName: String
    let bytesCopied: Int64

    func cleanup() {
        directory.remove(name)
    }
}

internal final class SafeDownloadDirectory: @unchecked Sendable {
    let url: URL

    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init(directory: URL) throws {
        guard directory.isFileURL else { throw DomainError.telegram(.downloadFailed) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = open(canonical.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DomainError.telegram(.downloadFailed) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw DomainError.telegram(.downloadFailed)
        }
        do {
            try Self.verifyRootPath(descriptor, canonical: canonical)
        } catch {
            close(descriptor)
            throw error
        }
        self.url = canonical
        self.descriptor = descriptor
        self.device = status.st_dev
        self.inode = status.st_ino
    }

    deinit {
        close(descriptor)
    }

    func stage(
        source: URL,
        sourceRoot: URL,
        expectedSize: Int64?,
        fileExtension: String?,
        cancellation: DownloadCancellationToken
    ) throws -> StagedDownload {
        try cancellation.withLock {}
        guard source.isFileURL else { throw DomainError.telegram(.downloadFailed) }
        let canonicalSourceRoot = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalSource != canonicalSourceRoot,
              canonicalSource.pathComponents.starts(with: canonicalSourceRoot.pathComponents) else {
            throw DomainError.telegram(.downloadFailed)
        }

        let sourceDescriptor = open(canonicalSource.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { throw DomainError.telegram(.downloadFailed) }
        defer { close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFREG else {
            throw DomainError.telegram(.downloadFailed)
        }
        if let expectedSize, expectedSize > 0, Int64(sourceStatus.st_size) != expectedSize {
            throw DomainError.telegram(.downloadFailed)
        }
        try verifyRoot()

        let name = ".telegram-download-\(UUID().uuidString).part"
        let destinationDescriptor = openat(
            descriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationDescriptor >= 0 else { throw DomainError.telegram(.downloadFailed) }
        var keepStagingFile = false
        defer {
            if !keepStagingFile { unlinkat(descriptor, name, 0) }
        }
        defer { close(destinationDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var copied: Int64 = 0
        while true {
            try cancellation.withLock {}
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return read(sourceDescriptor, base, buffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DomainError.telegram(.downloadFailed)
            }
            var offset = 0
            while offset < count {
                try cancellation.withLock {}
                let written = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let base = bytes.baseAddress?.advanced(by: offset) else { return -1 }
                    return write(destinationDescriptor, base, count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DomainError.telegram(.downloadFailed)
                }
                guard written > 0 else { throw DomainError.telegram(.downloadFailed) }
                offset += written
            }
            copied += Int64(count)
        }
        if let expectedSize, expectedSize > 0, copied != expectedSize {
            throw DomainError.telegram(.downloadFailed)
        }
        guard fsync(destinationDescriptor) == 0 || errno == EINVAL else {
            throw DomainError.telegram(.downloadFailed)
        }
        try verifyRoot()
        keepStagingFile = true
        return StagedDownload(
            directory: self,
            name: name,
            finalName: "telegram-\(UUID().uuidString)\(DownloadFileNaming.sanitizedExtension(fileExtension))",
            bytesCopied: copied
        )
    }

    func publish(_ staged: StagedDownload, cancellation: DownloadCancellationToken) throws -> URL {
        try cancellation.withLock {
            guard staged.directory === self else { throw DomainError.telegram(.downloadFailed) }
            try verifyRoot()
            guard linkat(descriptor, staged.name, descriptor, staged.finalName, 0) == 0 else {
                throw DomainError.telegram(.downloadFailed)
            }
            if unlinkat(descriptor, staged.name, 0) != 0 {
                unlinkat(descriptor, staged.finalName, 0)
                throw DomainError.telegram(.downloadFailed)
            }
            do {
                try verifyRoot()
            } catch {
                unlinkat(descriptor, staged.finalName, 0)
                throw error
            }
            return url.appendingPathComponent(staged.finalName)
        }
    }

    func remove(_ name: String) {
        unlinkat(descriptor, name, 0)
    }

    private func verifyRoot() throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_dev == device,
              status.st_ino == inode,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.systemNumber] as? NSNumber)?.int64Value == Int64(device),
              (attributes[.systemFileNumber] as? NSNumber)?.int64Value == Int64(inode) else {
            throw DomainError.telegram(.downloadFailed)
        }
        try Self.verifyRootPath(descriptor, canonical: url)
    }

    private static func verifyRootPath(_ descriptor: Int32, canonical: URL) throws {
        #if os(macOS) || os(iOS)
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0, String(cString: path) == canonical.path else {
            throw DomainError.telegram(.downloadFailed)
        }
        #endif
    }
}

internal enum DownloadFileNaming {
    static func fileExtension(forMimeType mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3":
            return ".mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a":
            return ".m4a"
        case "audio/ogg", "application/ogg":
            return ".ogg"
        case "audio/wav", "audio/x-wav":
            return ".wav"
        case "audio/flac", "audio/x-flac":
            return ".flac"
        default:
            return ""
        }
    }

    static func sanitizedExtension(_ extension: String?) -> String {
        guard let fileExtension,
              [".mp3", ".m4a", ".ogg", ".wav", ".flac"].contains(fileExtension) else {
            return ""
        }
        return fileExtension
    }
}
