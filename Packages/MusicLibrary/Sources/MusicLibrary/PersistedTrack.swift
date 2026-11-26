import Foundation
import MusicCore
import SwiftData

@Model
final class PersistedTrack {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var identityKey: String
    var telegramChatID: Int64
    var telegramMessageID: Int64
    var sourceChatID: Int64
    var sourceChatTitle: String
    var sourceChatKind: String
    var title: String
    var artist: String
    var duration: Double
    var fileSize: Int64?
    var importedAt: Date
    var localURLString: String

    init(track: Track) {
        id = track.id
        identityKey = "\(track.telegramIdentity.chatID):\(track.telegramIdentity.messageID)"
        telegramChatID = track.telegramIdentity.chatID
        telegramMessageID = track.telegramIdentity.messageID
        sourceChatID = track.sourceChat.id
        sourceChatTitle = track.sourceChat.title
        sourceChatKind = track.sourceChat.kind.rawValue
        title = track.title
        artist = track.artist
        duration = track.duration
        fileSize = track.fileSize
        importedAt = track.importedAt
        localURLString = track.localURL.absoluteString
    }

    func value() throws -> Track {
        do {
            guard let localURL = URL(string: localURLString), localURL.isFileURL,
                  let kind = TelegramChatKind(rawValue: sourceChatKind),
                  identityKey == "\(telegramChatID):\(telegramMessageID)" else {
                throw DomainError.library(.corruptData)
            }
            return try Track(
                id: id,
                telegramIdentity: TelegramAudioIdentity(chatID: telegramChatID, messageID: telegramMessageID),
                sourceChat: TelegramChat(
                    id: sourceChatID,
                    title: sourceChatTitle,
                    kind: kind
                ),
                title: title,
                artist: artist,
                duration: duration,
                fileSize: fileSize,
                importedAt: importedAt,
                localURL: localURL
            )
        } catch {
            throw DomainError.library(.corruptData)
        }
    }
}
