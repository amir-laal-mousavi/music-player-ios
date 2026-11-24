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
        if status == .imported, trackID == nil { throw DomainError.invalidImportItem }
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
        switch self {
        case .waiting:
            return next == .importing || next == .duplicate || next == .failed || next == .cancelled
        case .importing:
            return next == .imported || next == .duplicate || next == .failed || next == .cancelled
        case .imported, .duplicate, .failed, .cancelled:
            return false
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
        return try ImportItem(
            audio: audio,
            status: next,
            progress: progress,
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
    public let chatID: TelegramChat.ID
    public let items: [ImportItem]
    public let status: ImportJobStatus
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: ID = UUID(),
        chatID: TelegramChat.ID,
        items: [ImportItem],
        status: ImportJobStatus = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard chatID != 0 else { throw DomainError.invalidImportJob }
        guard items.allSatisfy({ $0.audio.chatID == chatID }) else {
            throw DomainError.invalidImportJob
        }
        var identities = Set<TelegramAudioIdentity>()
        for item in items {
            guard identities.insert(item.id).inserted else {
                throw DomainError.duplicateImportItem(item.id)
            }
        }
        self.id = id
        self.chatID = chatID
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
             (.waitingToResume, .queued):
            return true
        default:
            return false
        }
    }

    public func transition(to next: ImportJobStatus, updatedAt: Date = Date()) throws -> Self {
        guard canTransition(to: next) else {
            throw DomainError.invalidStateTransition(
                from: String(describing: status),
                to: String(describing: next)
            )
        }
        return try ImportJob(
            id: id,
            chatID: chatID,
            items: items,
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
    public let title: String
    public let artist: String
    public let duration: TimeInterval
    public let fileSize: Int64?
    public let localURL: URL

    public init(
        id: ID = UUID(),
        telegramIdentity: TelegramAudioIdentity,
        title: String,
        artist: String,
        duration: TimeInterval,
        fileSize: Int64? = nil,
        localURL: URL
    ) throws {
        guard duration.isFinite, duration >= 0 else { throw DomainError.invalidDuration }
        if let fileSize, fileSize < 0 { throw DomainError.invalidFileSize }
        guard localURL.isFileURL else { throw DomainError.invalidTrack }
        self.id = id
        self.telegramIdentity = telegramIdentity
        self.title = title
        self.artist = artist
        self.duration = duration
        self.fileSize = fileSize
        self.localURL = localURL
    }
}
