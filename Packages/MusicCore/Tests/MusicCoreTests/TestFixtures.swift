@testable import MusicCore
import Foundation

enum TestFixtures {
    static let chatID: TelegramChat.ID = -100_123

    static func audio(
        messageID: TelegramAudio.ID = 42,
        chatID: TelegramChat.ID = TestFixtures.chatID,
        title: String = "Fixture audio",
        performer: String = "Fixture artist"
    ) throws -> TelegramAudio {
        try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: chatID, messageID: messageID),
            fileReference: "test-file-\(chatID)-\(messageID)",
            title: title,
            performer: performer,
            duration: 120,
            fileSize: 1_024,
            mimeType: "audio/mpeg"
        )
    }

    static func track(audio: TelegramAudio, id: Track.ID = UUID()) throws -> Track {
        try Track(
            id: id,
            telegramIdentity: audio.identity,
            title: audio.title,
            artist: audio.performer,
            duration: audio.duration,
            fileSize: audio.fileSize,
            localURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).mp3")
        )
    }
}
