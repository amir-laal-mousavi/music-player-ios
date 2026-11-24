@testable import MusicCore
import Foundation
import XCTest

final class ModelValidationTests: XCTestCase {
    func testCurrentAccountHasStableIdentityAndMaskedPhone() throws {
        let account = try TestFixtures.account()
        let sameAccount = try TestFixtures.account()
        XCTAssertEqual(account.id, 700_001)
        XCTAssertEqual(account, sameAccount)
        XCTAssertEqual(account.maskedPhoneNumber, "••••0100")
        XCTAssertFalse(String(describing: account).contains("555 0100"))
        XCTAssertThrowsError(try TelegramAccount(id: 0, displayName: "Fixture", phoneNumber: "+1 555 0100")) { error in
            XCTAssertEqual(error as? DomainError, .invalidAccountIdentifier)
        }
        XCTAssertThrowsError(try TelegramAccount(id: 1, displayName: " ", phoneNumber: "+1 555 0100")) { error in
            XCTAssertEqual(error as? DomainError, .invalidAccountName)
        }
        XCTAssertThrowsError(try TelegramAccount(id: 1, displayName: "Fixture", phoneNumber: "1234")) { error in
            XCTAssertEqual(error as? DomainError, .invalidPhoneNumber)
        }
        XCTAssertThrowsError(
            try TelegramAccount(id: 1, displayName: "Fixture", phoneNumber: "+1 555 0100", username: " ")
        ) { error in
            XCTAssertEqual(error as? DomainError, .invalidAccountUsername)
        }
    }

    func testTelegramIdentityUsesChatAndMessageIDs() throws {
        let first = try TelegramAudioIdentity(chatID: -100_123, messageID: 42)
        let same = try TelegramAudioIdentity(chatID: -100_123, messageID: 42)
        let otherChat = try TelegramAudioIdentity(chatID: -100_124, messageID: 42)
        let otherMessage = try TelegramAudioIdentity(chatID: -100_123, messageID: 43)
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherChat)
        XCTAssertNotEqual(first, otherMessage)
        XCTAssertEqual(Set([first, same, otherChat, otherMessage]).count, 3)
        let firstAudio = try TestFixtures.audio(messageID: 42, chatID: -100_123)
        let otherChatAudio = try TestFixtures.audio(messageID: 42, chatID: -100_124)
        XCTAssertNotEqual(firstAudio.id, otherChatAudio.id)
        XCTAssertEqual(firstAudio.id, firstAudio.identity)
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
        XCTAssertNoThrow(try TelegramChat(id: -100_123, title: "Fixture chat", kind: .user))
        XCTAssertNoThrow(try TelegramChat(id: -100_123, title: "Fixture chat", kind: .group))
        XCTAssertNoThrow(try TelegramChat(id: -100_123, title: "Fixture chat", kind: .channel))
        XCTAssertThrowsError(try TelegramChat(id: 0, title: "Fixture chat", kind: .group)) { error in
            XCTAssertEqual(error as? DomainError, .invalidChatIdentifier)
        }
        XCTAssertThrowsError(try TelegramChat(id: 1, title: " \n", kind: .user)) { error in
            XCTAssertEqual(error as? DomainError, .invalidChatTitle)
        }

        let identity = try TelegramAudioIdentity(chatID: 1, messageID: 2)
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileID: 0, fileReference: "file", duration: 1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidFileIdentifier)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileID: -1, fileReference: "file", duration: 1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidFileIdentifier)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileID: 7, fileReference: " ", duration: 1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidFileReference)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileID: 7, fileReference: "file", duration: -1)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDuration)
        }
        XCTAssertThrowsError(try TelegramAudio(identity: identity, fileID: 7, fileReference: "file", duration: .nan)) { error in
            XCTAssertEqual(error as? DomainError, .invalidDuration)
        }
        XCTAssertThrowsError(
            try TelegramAudio(identity: identity, fileID: 7, fileReference: "file", duration: 1, fileSize: -1)
        ) { error in
            XCTAssertEqual(error as? DomainError, .invalidFileSize)
        }
        XCTAssertThrowsError(
            try TelegramAudio(identity: identity, fileID: 7, fileReference: "file", duration: 1, mimeType: "")
        ) { error in
            XCTAssertEqual(error as? DomainError, .invalidMIMEType)
        }
        let audio = try TelegramAudio(identity: identity, fileID: 7, fileReference: "file", duration: 1)
        XCTAssertEqual(audio.fileID, 7)
    }

    func testAudioPageRequestAndCursorValidation() throws {
        let older = try TestFixtures.audio(messageID: 10)
        let newer = try TestFixtures.audio(messageID: 11)
        let request = try TelegramAudioPageRequest(chatID: TestFixtures.chatID, beforeMessageID: 12, limit: 2)
        XCTAssertEqual(request.beforeMessageID, 12)
        XCTAssertEqual(request.limit, 2)
        XCTAssertNoThrow(try TelegramAudioPageRequest(
            chatID: TestFixtures.chatID,
            beforeMessageID: nil,
            limit: TelegramAudioPageRequest.maximumLimit
        ))
        XCTAssertThrowsError(try TelegramAudioPageRequest(chatID: 0, beforeMessageID: nil, limit: 2))
        XCTAssertThrowsError(try TelegramAudioPageRequest(chatID: TestFixtures.chatID, beforeMessageID: 0, limit: 2))
        XCTAssertThrowsError(try TelegramAudioPageRequest(chatID: TestFixtures.chatID, beforeMessageID: -1, limit: 2))
        XCTAssertThrowsError(try TelegramAudioPageRequest(chatID: TestFixtures.chatID, beforeMessageID: nil, limit: 0))
        XCTAssertThrowsError(try TelegramAudioPageRequest(
            chatID: TestFixtures.chatID,
            beforeMessageID: nil,
            limit: TelegramAudioPageRequest.maximumLimit + 1
        ))

        let page = try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [newer, older], nextCursor: 10)
        XCTAssertEqual(page.nextCursor, 10)
        XCTAssertNoThrow(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [], nextCursor: nil))
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [older, newer], nextCursor: 11))
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [older, older], nextCursor: 10))
        XCTAssertThrowsError(try TelegramAudioPage(chatID: TestFixtures.chatID, messages: [older], nextCursor: 11))
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
