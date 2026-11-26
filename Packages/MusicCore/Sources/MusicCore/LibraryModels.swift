import Foundation

public enum ImportItemStatus: Sendable, Equatable, Hashable {
    case waiting
    case importing
    case imported
    case duplicate
    case failed
    case cancelled
}

public struct ImportItem: Identifiable, Sendable, Equatable {
    public typealias ID = TelegramAudioIdentity

    public let audio: TelegramAudio
    public let status: ImportItemStatus
    public let progress: DownloadProgress?
    public let trackID: Track.ID?
    public let error: DomainError?

    public var id: ID { audio.identity }

    public init(
        audio: TelegramAudio,
        status: ImportItemStatus = .waiting,
        progress: DownloadProgress? = nil,
        trackID: Track.ID? = nil,
        error: DomainError? = nil
    ) throws {
        if status == .imported || status == .duplicate, trackID == nil {
            throw DomainError.invalidImportItem
        }
        if status == .failed, error == nil { throw DomainError.invalidImportItem }
        if status != .failed, error != nil { throw DomainError.invalidImportItem }
        if status != .imported, status != .duplicate, trackID != nil {
            throw DomainError.invalidImportItem
        }
        self.audio = audio
        self.status = status
        self.progress = progress
        self.trackID = trackID
        self.error = error
    }

    public func canTransition(to next: ImportItemStatus) -> Bool {
        switch status {
        case .waiting:
            return next == .importing || next == .duplicate || next == .failed || next == .cancelled
        case .importing:
            return next == .waiting || next == .imported || next == .duplicate || next == .failed || next == .cancelled
        case .imported, .duplicate:
            return false
        case .failed, .cancelled:
            return next == .waiting
        }
    }

    public func transition(
        to next: ImportItemStatus,
        progress: DownloadProgress? = nil,
        trackID: Track.ID? = nil,
        error: DomainError? = nil
    ) throws -> Self {
        guard canTransition(to: next) else {
            throw DomainError.invalidStateTransition(
                from: String(describing: status),
                to: String(describing: next)
            )
        }
        let nextProgress = next == .waiting ? progress ?? self.progress : progress
        return try ImportItem(
            audio: audio,
            status: next,
            progress: nextProgress,
            trackID: trackID,
            error: error
        )
    }
}

public enum ImportJobStatus: Sendable, Equatable, Hashable {
    case queued
    case active
    case pausing
    case paused
    case completed
    case partialFailure
    case cancelled
    /// A paused or queued job blocked by authentication, connectivity, or app suspension.
    case waitingToResume
}

public struct ImportJob: Identifiable, Sendable, Equatable {
    public typealias ID = UUID

    public let id: ID
    public let sourceChat: TelegramChat
    public let items: [ImportItem]
    public let status: ImportJobStatus
    public let createdAt: Date
    public let updatedAt: Date

    public var chatID: TelegramChat.ID { sourceChat.id }

    public init(
        id: ID = UUID(),
        sourceChat: TelegramChat,
        items: [ImportItem],
        status: ImportJobStatus = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt else {
            throw DomainError.invalidImportJob
        }
        guard items.allSatisfy({ $0.audio.chatID == sourceChat.id }) else {
            throw DomainError.invalidImportJob
        }
        var identities = Set<TelegramAudioIdentity>()
        for item in items {
            guard identities.insert(item.id).inserted else {
                throw DomainError.duplicateImportItem(item.id)
            }
        }
        self.id = id
        self.sourceChat = sourceChat
        self.items = items
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func canTransition(to next: ImportJobStatus) -> Bool {
        switch (status, next) {
        case (.queued, .active),
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
             (.cancelled, .queued):
            return true
        default:
            return false
        }
    }

    /// Retrying a cancelled or partially failed job resets only unfinished items.
    public func transition(to next: ImportJobStatus, updatedAt: Date = Date()) throws -> Self {
        guard canTransition(to: next) else {
            throw DomainError.invalidStateTransition(
                from: String(describing: status),
                to: String(describing: next)
            )
        }
        var nextItems = items
        if next == .queued, status == .partialFailure || status == .cancelled {
            nextItems = try items.map { item in
                if item.status == .failed || item.status == .cancelled || item.status == .importing {
                    return try item.transition(to: .waiting)
                }
                return item
            }
        }
        return try ImportJob(
            id: id,
            sourceChat: sourceChat,
            items: nextItems,
            status: next,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct Track: Identifiable, Sendable, Equatable {
    public typealias ID = UUID

    public let id: ID
    public let telegramIdentity: TelegramAudioIdentity
    public let sourceChat: TelegramChat
    public let title: String
    public let artist: String
    public let duration: TimeInterval
    public let fileSize: Int64?
    public let importedAt: Date
    public let localURL: URL
    /// Cover art copied next to the audio file, or nil when the source had none.
    public let artworkURL: URL?

    public init(
        id: ID = UUID(),
        telegramIdentity: TelegramAudioIdentity,
        sourceChat: TelegramChat,
        title: String,
        artist: String,
        duration: TimeInterval,
        fileSize: Int64? = nil,
        importedAt: Date = Date(),
        localURL: URL,
        artworkURL: URL? = nil
    ) throws {
        guard sourceChat.id == telegramIdentity.chatID else { throw DomainError.invalidTrack }
        guard duration.isFinite, duration >= 0 else { throw DomainError.invalidDuration }
        if let fileSize, fileSize < 0 { throw DomainError.invalidFileSize }
        guard importedAt.timeIntervalSince1970.isFinite else { throw DomainError.invalidTrack }
        guard localURL.isFileURL else { throw DomainError.invalidTrack }
        if let artworkURL, !artworkURL.isFileURL { throw DomainError.invalidTrack }
        self.id = id
        self.telegramIdentity = telegramIdentity
        self.sourceChat = sourceChat
        self.title = title
        self.artist = artist
        self.duration = duration
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.localURL = localURL
        self.artworkURL = artworkURL
    }
}

/// A user-created collection of library tracks, in play order.
public struct Playlist: Identifiable, Sendable, Equatable {
    public typealias ID = UUID
    public static let maximumNameLength = 80

    public let id: ID
    public let name: String
    public let trackIDs: [Track.ID]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: ID = UUID(),
        name: String,
        trackIDs: [Track.ID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumNameLength else {
            throw DomainError.invalidPlaylistName
        }
        guard Set(trackIDs).count == trackIDs.count else {
            throw DomainError.invalidPlaylistTracks
        }
        guard createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt else {
            throw DomainError.invalidPlaylist
        }
        self.id = id
        self.name = trimmed
        self.trackIDs = trackIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func adding(_ trackIDs: [Track.ID], at date: Date = Date()) throws -> Playlist {
        var next = self.trackIDs
        for id in trackIDs where !next.contains(id) {
            next.append(id)
        }
        return try Playlist(
            id: id,
            name: name,
            trackIDs: next,
            createdAt: createdAt,
            updatedAt: max(date, updatedAt)
        )
    }

    public func removing(_ trackID: Track.ID, at date: Date = Date()) throws -> Playlist {
        try Playlist(
            id: id,
            name: name,
            trackIDs: trackIDs.filter { $0 != trackID },
            createdAt: createdAt,
            updatedAt: max(date, updatedAt)
        )
    }

    public func renamed(_ newName: String, at date: Date = Date()) throws -> Playlist {
        try Playlist(
            id: id,
            name: newName,
            trackIDs: trackIDs,
            createdAt: createdAt,
            updatedAt: max(date, updatedAt)
        )
    }
}
