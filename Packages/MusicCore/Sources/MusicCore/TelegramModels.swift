import Foundation

public enum TelegramAuthState: Sendable, Equatable {
    case unauthenticated
    case waitingForPhone
    case waitingForCode
    case waitingForPassword
    case authenticated
    case loggingOut
    case failure(DomainError)

    public func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.unauthenticated, .waitingForPhone),
             (.unauthenticated, .authenticated),
             (.unauthenticated, .failure),
             (.waitingForPhone, .waitingForCode),
             (.waitingForPhone, .authenticated),
             (.waitingForPhone, .failure),
             (.waitingForCode, .waitingForPassword),
             (.waitingForCode, .authenticated),
             (.waitingForCode, .failure),
             (.waitingForPassword, .authenticated),
             (.waitingForPassword, .failure),
             (.authenticated, .loggingOut),
             (.authenticated, .failure),
             (.loggingOut, .unauthenticated),
             (.loggingOut, .authenticated),
             (.loggingOut, .failure),
             (.failure, .unauthenticated):
            return true
        default:
            return false
        }
    }

    public func transition(to next: Self) throws -> Self {
        guard canTransition(to: next) else {
            throw DomainError.invalidStateTransition(
                from: String(describing: self),
                to: String(describing: next)
            )
        }
        return next
    }
}

public func validatedPhoneNumber(_ phone: String) throws -> String {
    let value = phone.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw DomainError.invalidPhoneNumber }
    return value
}

public func validatedAuthenticationCode(_ code: String) throws -> String {
    let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw DomainError.invalidAuthenticationCode }
    return value
}

public func validatedPassword(_ password: String) throws -> String {
    guard !password.isEmpty else { throw DomainError.invalidPassword }
    return password
}

public struct TelegramChat: Identifiable, Sendable, Equatable {
    public typealias ID = Int64

    public let id: ID
    public let title: String

    public init(id: ID, title: String) throws {
        guard id != 0 else { throw DomainError.invalidChatIdentifier }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainError.invalidChatTitle
        }
        self.id = id
        self.title = title
    }
}

public struct TelegramAudioIdentity: Hashable, Sendable {
    public let chatID: TelegramChat.ID
    public let messageID: Int64

    public init(chatID: TelegramChat.ID, messageID: Int64) throws {
        guard chatID != 0 else { throw DomainError.invalidChatIdentifier }
        guard messageID > 0 else { throw DomainError.invalidAudioIdentifier }
        self.chatID = chatID
        self.messageID = messageID
    }
}

public struct TelegramAudio: Identifiable, Sendable, Equatable {
    public typealias ID = Int64

    public let identity: TelegramAudioIdentity
    public let fileReference: String
    public let title: String
    public let performer: String
    public let duration: TimeInterval
    public let fileSize: Int64?
    public let mimeType: String?

    public var id: ID { identity.messageID }
    public var chatID: TelegramChat.ID { identity.chatID }

    public init(
        identity: TelegramAudioIdentity,
        fileReference: String,
        title: String = "",
        performer: String = "",
        duration: TimeInterval,
        fileSize: Int64? = nil,
        mimeType: String? = nil
    ) throws {
        guard !fileReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainError.invalidFileReference
        }
        guard duration.isFinite, duration >= 0 else { throw DomainError.invalidDuration }
        if let fileSize, fileSize < 0 { throw DomainError.invalidFileSize }
        if let mimeType, mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DomainError.invalidMIMEType
        }
        self.identity = identity
        self.fileReference = fileReference
        self.title = title
        self.performer = performer
        self.duration = duration
        self.fileSize = fileSize
        self.mimeType = mimeType
    }
}

public struct TelegramAudioPageRequest: Sendable, Equatable {
    public let chatID: TelegramChat.ID
    public let afterMessageID: TelegramAudio.ID?
    public let limit: Int

    public init(chatID: TelegramChat.ID, afterMessageID: TelegramAudio.ID?, limit: Int) throws {
        guard chatID != 0, limit > 0 else { throw DomainError.invalidAudioPageRequest }
        if let afterMessageID, afterMessageID <= 0 {
            throw DomainError.invalidAudioPageRequest
        }
        self.chatID = chatID
        self.afterMessageID = afterMessageID
        self.limit = limit
    }
}

public struct TelegramAudioPage: Sendable, Equatable {
    public let chatID: TelegramChat.ID
    public let messages: [TelegramAudio]
    public let nextCursor: TelegramAudio.ID?

    public init(chatID: TelegramChat.ID, messages: [TelegramAudio], nextCursor: TelegramAudio.ID?) throws {
        guard chatID != 0 else { throw DomainError.invalidAudioPage }
        if let nextCursor, nextCursor <= 0 { throw DomainError.invalidAudioPage }
        guard messages.allSatisfy({ $0.chatID == chatID }) else {
            throw DomainError.invalidAudioPage
        }
        for index in messages.indices.dropFirst() where messages[index - 1].id >= messages[index].id {
            throw DomainError.invalidAudioPage
        }
        if let nextCursor, messages.last?.id != nextCursor {
            throw DomainError.invalidAudioPage
        }
        self.chatID = chatID
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public struct DownloadProgress: Sendable, Equatable {
    /// A nil totalBytes means that the total length is unknown.
    public let totalBytes: Int64?
    public let completedBytes: Int64

    public init(totalBytes: Int64?, completedBytes: Int64) throws {
        if let totalBytes, totalBytes < 0 { throw DomainError.invalidDownloadProgress }
        guard completedBytes >= 0 else { throw DomainError.invalidDownloadProgress }
        if let totalBytes, completedBytes > totalBytes {
            throw DomainError.invalidDownloadProgress
        }
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(completedBytes) / Double(totalBytes)
    }
}
