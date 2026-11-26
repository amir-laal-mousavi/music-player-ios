import Foundation
import MusicCore
import SwiftData

struct ImportJobSnapshot: Codable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    fileprivate let sourceChat: ChatSnapshot
    fileprivate let items: [ItemSnapshot]
    let status: String
    let createdAt: Date
    let updatedAt: Date

    init(_ job: ImportJob) {
        version = Self.currentVersion
        id = job.id
        sourceChat = ChatSnapshot(job.sourceChat)
        items = job.items.map(ItemSnapshot.init)
        status = String(describing: job.status)
        createdAt = job.createdAt
        updatedAt = job.updatedAt
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    func job() throws -> ImportJob {
        guard version == Self.currentVersion else { throw DomainError.library(.corruptData) }
        do {
            return try ImportJob(
                id: id,
                sourceChat: sourceChat.value(),
                items: items.map { try $0.value() },
                status: try jobStatus(status),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw DomainError.library(.corruptData)
        }
    }

    private func jobStatus(_ value: String) throws -> ImportJobStatus {
        switch value {
        case "queued": return .queued
        case "active": return .active
        case "pausing": return .pausing
        case "paused": return .paused
        case "completed": return .completed
        case "partialFailure": return .partialFailure
        case "cancelled": return .cancelled
        case "waitingToResume": return .waitingToResume
        default: throw DomainError.library(.corruptData)
        }
    }
}

private struct ChatSnapshot: Codable {
    let id: Int64
    let title: String
    let kind: String

    init(_ chat: TelegramChat) {
        id = chat.id
        title = chat.title
        kind = chat.kind.rawValue
    }

    func value() throws -> TelegramChat {
        guard let kind = TelegramChatKind(rawValue: kind) else { throw DomainError.library(.corruptData) }
        return try TelegramChat(id: id, title: title, kind: kind)
    }
}

private struct ItemSnapshot: Codable {
    let audio: AudioSnapshot
    let status: String
    let progress: ProgressSnapshot?
    let trackID: UUID?
    let error: ErrorSnapshot?

    init(_ item: ImportItem) {
        audio = AudioSnapshot(item.audio)
        status = String(describing: item.status)
        progress = item.progress.map(ProgressSnapshot.init)
        trackID = item.trackID
        error = item.error.map(ErrorSnapshot.init)
    }

    func value() throws -> ImportItem {
        let status: ImportItemStatus
        switch self.status {
        case "waiting": status = .waiting
        case "importing": status = .importing
        case "imported": status = .imported
        case "duplicate": status = .duplicate
        case "failed": status = .failed
        case "cancelled": status = .cancelled
        default: throw DomainError.library(.corruptData)
        }
        return try ImportItem(
            audio: audio.value(),
            status: status,
            progress: try progress?.value(),
            trackID: trackID,
            error: try error?.value()
        )
    }
}

private struct AudioSnapshot: Codable {
    let chatID: Int64
    let messageID: Int64
    let fileID: Int32
    let fileReference: String
    let title: String
    let performer: String
    let duration: Double
    let fileSize: Int64?
    let mimeType: String?

    init(_ audio: TelegramAudio) {
        chatID = audio.chatID
        messageID = audio.messageID
        fileID = audio.fileID
        fileReference = audio.fileReference
        title = audio.title
        performer = audio.performer
        duration = audio.duration
        fileSize = audio.fileSize
        mimeType = audio.mimeType
    }

    func value() throws -> TelegramAudio {
        try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: chatID, messageID: messageID),
            fileID: fileID,
            fileReference: fileReference,
            title: title,
            performer: performer,
            duration: duration,
            fileSize: fileSize,
            mimeType: mimeType
        )
    }
}

private struct ProgressSnapshot: Codable {
    let totalBytes: Int64?
    let completedBytes: Int64

    init(_ progress: DownloadProgress) {
        totalBytes = progress.totalBytes
        completedBytes = progress.completedBytes
    }

    func value() throws -> DownloadProgress {
        try DownloadProgress(totalBytes: totalBytes, completedBytes: completedBytes)
    }
}

private struct ErrorSnapshot: Codable {
    let kind: String
    var chatID: Int64?
    var messageID: Int64?
    var id: UUID?
    var from: String?
    var to: String?
    var nested: String?

    init(_ error: DomainError) {
        switch error {
        case .invalidPhoneNumber: kind = "invalidPhoneNumber"
        case .invalidAuthenticationCode: kind = "invalidAuthenticationCode"
        case .invalidPassword: kind = "invalidPassword"
        case .invalidAccountIdentifier: kind = "invalidAccountIdentifier"
        case .invalidAccountName: kind = "invalidAccountName"
        case .invalidAccountUsername: kind = "invalidAccountUsername"
        case .invalidChatIdentifier: kind = "invalidChatIdentifier"
        case .invalidAudioIdentifier: kind = "invalidAudioIdentifier"
        case .invalidChatTitle: kind = "invalidChatTitle"
        case .invalidFileIdentifier: kind = "invalidFileIdentifier"
        case .invalidFileReference: kind = "invalidFileReference"
        case .invalidFileSize: kind = "invalidFileSize"
        case .invalidMIMEType: kind = "invalidMIMEType"
        case .invalidDuration: kind = "invalidDuration"
        case .invalidAudioPageRequest: kind = "invalidAudioPageRequest"
        case .invalidAudioPage: kind = "invalidAudioPage"
        case .invalidDownloadProgress: kind = "invalidDownloadProgress"
        case .invalidTrack: kind = "invalidTrack"
        case .invalidImportItem: kind = "invalidImportItem"
        case .duplicateImportItem(let identity):
            kind = "duplicateImportItem"
            chatID = identity.chatID
            messageID = identity.messageID
        case .invalidImportJob: kind = "invalidImportJob"
        case .invalidPlaybackState: kind = "invalidPlaybackState"
        case .invalidPlaybackQueue: kind = "invalidPlaybackQueue"
        case .invalidStateTransition(let from, let to):
            kind = "invalidStateTransition"
            self.from = from
            self.to = to
        case .unauthenticated: kind = "unauthenticated"
        case .chatNotFound(let chatID):
            kind = "chatNotFound"
            self.chatID = chatID
        case .audioNotFound(let identity):
            kind = "audioNotFound"
            chatID = identity.chatID
            messageID = identity.messageID
        case .duplicateTrack(let identity):
            kind = "duplicateTrack"
            chatID = identity.chatID
            messageID = identity.messageID
        case .trackNotFound(let id):
            kind = "trackNotFound"
            self.id = id
        case .importJobNotFound(let id):
            kind = "importJobNotFound"
            self.id = id
        case .invalidPlaylist: kind = "invalidPlaylist"
        case .invalidPlaylistName: kind = "invalidPlaylistName"
        case .invalidPlaylistTracks: kind = "invalidPlaylistTracks"
        case .playlistNotFound(let id):
            kind = "playlistNotFound"
            self.id = id
        case .telegram(let error):
            kind = "telegram"
            nested = telegramValue(error)
        case .library(let error):
            kind = "library"
            nested = libraryValue(error)
        case .playback(let error):
            kind = "playback"
            nested = playbackValue(error)
        }
    }

    func value() throws -> DomainError {
        switch kind {
        case "invalidPhoneNumber": return .invalidPhoneNumber
        case "invalidAuthenticationCode": return .invalidAuthenticationCode
        case "invalidPassword": return .invalidPassword
        case "invalidAccountIdentifier": return .invalidAccountIdentifier
        case "invalidAccountName": return .invalidAccountName
        case "invalidAccountUsername": return .invalidAccountUsername
        case "invalidChatIdentifier": return .invalidChatIdentifier
        case "invalidAudioIdentifier": return .invalidAudioIdentifier
        case "invalidChatTitle": return .invalidChatTitle
        case "invalidFileIdentifier": return .invalidFileIdentifier
        case "invalidFileReference": return .invalidFileReference
        case "invalidFileSize": return .invalidFileSize
        case "invalidMIMEType": return .invalidMIMEType
        case "invalidDuration": return .invalidDuration
        case "invalidAudioPageRequest": return .invalidAudioPageRequest
        case "invalidAudioPage": return .invalidAudioPage
        case "invalidDownloadProgress": return .invalidDownloadProgress
        case "invalidTrack": return .invalidTrack
        case "invalidImportItem": return .invalidImportItem
        case "duplicateImportItem":
            return .duplicateImportItem(try identity())
        case "invalidImportJob": return .invalidImportJob
        case "invalidPlaylist": return .invalidPlaylist
        case "invalidPlaylistName": return .invalidPlaylistName
        case "invalidPlaylistTracks": return .invalidPlaylistTracks
        case "playlistNotFound":
            guard let id else { throw DomainError.library(.corruptData) }
            return .playlistNotFound(id)
        case "invalidPlaybackState": return .invalidPlaybackState
        case "invalidPlaybackQueue": return .invalidPlaybackQueue
        case "invalidStateTransition":
            guard let from, let to else { throw DomainError.library(.corruptData) }
            return .invalidStateTransition(from: from, to: to)
        case "unauthenticated": return .unauthenticated
        case "chatNotFound":
            guard let chatID else { throw DomainError.library(.corruptData) }
            return .chatNotFound(chatID)
        case "audioNotFound": return .audioNotFound(try identity())
        case "duplicateTrack": return .duplicateTrack(try identity())
        case "trackNotFound":
            guard let id else { throw DomainError.library(.corruptData) }
            return .trackNotFound(id)
        case "importJobNotFound":
            guard let id else { throw DomainError.library(.corruptData) }
            return .importJobNotFound(id)
        case "telegram":
            guard let nested, let error = telegramError(nested) else {
                throw DomainError.library(.corruptData)
            }
            return .telegram(error)
        case "library":
            guard let nested, let error = libraryError(nested) else {
                throw DomainError.library(.corruptData)
            }
            return .library(error)
        case "playback":
            guard let nested, let error = playbackError(nested) else {
                throw DomainError.library(.corruptData)
            }
            return .playback(error)
        default: throw DomainError.library(.corruptData)
        }
    }

    private func identity() throws -> TelegramAudioIdentity {
        guard let chatID, let messageID else { throw DomainError.library(.corruptData) }
        return try TelegramAudioIdentity(chatID: chatID, messageID: messageID)
    }

    private func telegramValue(_ error: TelegramGatewayError) -> String {
        switch error {
        case .notAuthorized: return "notAuthorized"
        case .networkUnavailable: return "networkUnavailable"
        case .rateLimited: return "rateLimited"
        case .serviceUnavailable: return "serviceUnavailable"
        case .invalidResponse: return "invalidResponse"
        case .downloadFailed: return "downloadFailed"
        }
    }

    private func telegramError(_ value: String) -> TelegramGatewayError? {
        switch value {
        case "notAuthorized": return .notAuthorized
        case "networkUnavailable": return .networkUnavailable
        case "rateLimited": return .rateLimited
        case "serviceUnavailable": return .serviceUnavailable
        case "invalidResponse": return .invalidResponse
        case "downloadFailed": return .downloadFailed
        default: return nil
        }
    }

    private func libraryValue(_ error: LibraryStoreError) -> String {
        switch error {
        case .unavailable: return "unavailable"
        case .corruptData: return "corruptData"
        case .writeFailed: return "writeFailed"
        }
    }

    private func libraryError(_ value: String) -> LibraryStoreError? {
        switch value {
        case "unavailable": return .unavailable
        case "corruptData": return .corruptData
        case "writeFailed": return .writeFailed
        default: return nil
        }
    }

    private func playbackValue(_ error: PlayerError) -> String {
        switch error {
        case .notReady: return "notReady"
        case .fileUnavailable: return "fileUnavailable"
        case .unsupportedFormat: return "unsupportedFormat"
        case .playbackFailed: return "playbackFailed"
        case .queueBoundary: return "queueBoundary"
        }
    }

    private func playbackError(_ value: String) -> PlayerError? {
        switch value {
        case "notReady": return .notReady
        case "fileUnavailable": return .fileUnavailable
        case "unsupportedFormat": return .unsupportedFormat
        case "playbackFailed": return .playbackFailed
        case "queueBoundary": return .queueBoundary
        default: return nil
        }
    }
}

@Model
final class PersistedImportJob {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var payload: Data

    init(job: ImportJob) throws {
        id = job.id
        createdAt = job.createdAt
        payload = try ImportJobSnapshot(job).encoded()
    }

    func update(with job: ImportJob) throws {
        guard job.id == id, job.createdAt == createdAt else { throw DomainError.library(.corruptData) }
        payload = try ImportJobSnapshot(job).encoded()
    }

    func value() throws -> ImportJob {
        let snapshot: ImportJobSnapshot
        do {
            snapshot = try JSONDecoder().decode(ImportJobSnapshot.self, from: payload)
        } catch {
            throw DomainError.library(.corruptData)
        }
        let job = try snapshot.job()
        guard job.id == id, job.createdAt == createdAt else { throw DomainError.library(.corruptData) }
        return job
    }
}
