@testable import MusicCore
import Foundation

enum TestFixtures {
    static let chatID: TelegramChat.ID = -100_123

    static func chat(
        id: TelegramChat.ID = TestFixtures.chatID,
        title: String = "Fixture chat",
        kind: TelegramChatKind = .group
    ) throws -> TelegramChat {
        try TelegramChat(id: id, title: title, kind: kind)
    }

    static func account() throws -> TelegramAccount {
        try TelegramAccount(
            id: 700_001,
            displayName: "Fixture User",
            phoneNumber: "+1 555 0100",
            username: "fixture_user"
        )
    }

    static func audio(
        messageID: TelegramAudio.MessageID = 42,
        chatID: TelegramChat.ID = TestFixtures.chatID,
        fileID: Int32 = 7,
        title: String = "Fixture audio",
        performer: String = "Fixture artist"
    ) throws -> TelegramAudio {
        try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: chatID, messageID: messageID),
            fileID: fileID,
            fileReference: "test-file-\(chatID)-\(messageID)",
            title: title,
            performer: performer,
            duration: 120,
            fileSize: 1_024,
            mimeType: "audio/mpeg"
        )
    }

    static func track(
        audio: TelegramAudio,
        id: Track.ID = UUID(),
        importedAt: Date = Date(timeIntervalSince1970: 100)
    ) throws -> Track {
        try Track(
            id: id,
            telegramIdentity: audio.identity,
            sourceChat: chat(id: audio.chatID),
            title: audio.title,
            artist: audio.performer,
            duration: audio.duration,
            fileSize: audio.fileSize,
            importedAt: importedAt,
            localURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).mp3")
        )
    }
}
