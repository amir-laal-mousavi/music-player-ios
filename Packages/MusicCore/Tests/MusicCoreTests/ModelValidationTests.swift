@testable import MusicCore
import Foundation
import XCTest

final class ModelValidationTests: XCTestCase {
    func testTelegramIdentityUsesChatAndMessageIDs() throws {
        let first = try TelegramAudioIdentity(chatID: -100_123, messageID: 42)
        let same = try TelegramAudioIdentity(chatID: -100_123, messageID: 42)
        let otherChat = try TelegramAudioIdentity(chatID: -100_124, messageID: 42)
        let otherMessage = try TelegramAudioIdentity(chatID: -100_123, messageID: 43)
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherChat)
        XCTAssertNotEqual(first, otherMessage)
        XCTAssertEqual(Set([first, same, otherChat, otherMessage]).count, 3)
        XCTAssertThrowsError(try TelegramAudioIdentity(chatID: 0, messageID: 42)) { error in
            XCTAssertEqual(error as? DomainError, .invalidChatIdentifier)
        }
        XCTAssertThrowsError(try TelegramAudioIdentity(chatID: 1, messageID: 0)) { error in
            XCTAssertEqual(error as? DomainError, .invalidAudioIdentifier)
        }
        XCTAssertThrowsError(try TelegramAudioIdentity(chatID: 1, messageID: -1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidAudioIdentifier)
        }
    }

    func testChatAndAudioValidation() throws {
        XCTAssertNoThrow(try TelegramChat(id: -100_123, title: "Fixture chat"))
        XCTAssertThrowsError(try TelegramChat(id: 0, title: "Fixture chat")) { error in
            XCTAssertEqual(error as? DomainError, .invalidChatIdentifier)
        }
        XCTAssertThrowsError(try TelegramChat(id: 1, title: " \n")) { error in
            XCTAssertEqual(error as? DomainError, .invalidChatTitle)
        }

        let identity = try TelegramAudioIdentity(chatID: 1, messageID: 2)
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileReference: " ", duration: 1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidFileReference)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileReference: "file", duration: -1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDuration)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileReference: "file", duration: .nan)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDuration)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileReference: "file", duration: 1, fileSize: -1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidFileSize)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileReference: "file", duration: 1, mimeType: "")) { error in
            XCTAssertEqual(error as? DomainError, .invalidMIMEType)
        }
    }

    func testAudioPageRequestAndCursorValidation() throws {
        let first = try TestFixtures.audio(messageID: 10)
        let second = try TestFixtures.audio(messageID: 11)
        let request = try TelegramAudioPageRequest(chatID: TestFixtures.chatID, afterMessageID: 9, limit: 2)
        XCTAssertEqual(request.afterMessageID, 9)
        XCTAssertEqual(request.limit, 2)
        XCTAssertThrowsError(try TelegramAudioPageRequest(chatID: 0, afterMessageID: nil, limit: 2))
        XCTAssertThrowsError(try TelegramAudioPageRequest(chatID: TestFixtures.chatID, afterMessageID: 0, limit: 2))
        XCTAssertThrowsError(try TelegramAudioPageRequest(chatID: TestFixtures.chatID, afterMessageID: nil, limit: 0))

        let page = try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [first, second], nextCursor: 11)
        XCTAssertEqual(page.nextCursor, 11)
        XCTAssertNoThrow(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [], nextCursor: nil))
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [second, first], nextCursor: 10))
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [first, first], nextCursor: 10))
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [first], nextCursor: 11))
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [], nextCursor: 10))
        let otherChat = try TestFixtures.audio(chatID: TestFixtures.chatID + 1)
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [otherChat], nextCursor: 42))
    }

    func testTrackUsesLocalUUIDAndRejectsInvalidLocalFiles() throws {
        let audio = try TestFixtures.audio()
        let id = UUID()
        let track = try TestFixtures.track(audio: audio, id: id)
        let sameSource = try TestFixtures.track(audio: audio)
        XCTAssertEqual(track.id, id)
        XCTAssertNotEqual(track.id, sameSource.id)
        XCTAssertEqual(track.telegramIdentity, sameSource.telegramIdentity)
        XCTAssertThrowsError(
            try Track(
                telegramIdentity: audio.identity,
                title: audio.title,
                artist: audio.performer,
                duration: audio.duration,
                localURL: URL(string: "https://example.invalid/audio.mp3")!
            )
        ) { error in
            XCTAssertEqual(error as? DomainError, .invalidTrack)
        }
        XCTAssertThrowsError(
            try Track(
                telegramIdentity: audio.identity,
                title: audio.title,
                artist: audio.performer,
                duration: .infinity,
                localURL: URL(fileURLWithPath: "/tmp/audio.mp3")
            )
        ) { error in
            XCTAssertEqual(error as? DomainError, .invalidDuration)
        }
    }
}
