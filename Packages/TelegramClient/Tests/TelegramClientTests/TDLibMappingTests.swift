import Foundation
import MusicCore
import XCTest
@testable import TelegramClient

final class TDLibMappingTests: XCTestCase {
    func testAuthorizationStatesUsePinnedTDLibNames() throws {
        let cases: [(String, TelegramAuthState)] = [
            ("authorizationStateWaitTdlibParameters", .unauthenticated),
            ("authorizationStateWaitPhoneNumber", .waitingForPhone),
            ("authorizationStateWaitCode", .waitingForCode),
            ("authorizationStateWaitPassword", .waitingForPassword),
            ("authorizationStateReady", .authenticated),
            ("authorizationStateLoggingOut", .loggingOut),
            ("authorizationStateClosing", .loggingOut),
            ("authorizationStateClosed", .unauthenticated)
        ]
        for (type, expected) in cases {
            XCTAssertEqual(try TDLibMapper.authState(from: SyntheticFixtures.auth(type)), expected)
        }
        XCTAssertEqual(
            try TDLibMapper.authState(from: SyntheticFixtures.auth("authorizationStateUnknown")),
            .failure(.telegram(.invalidResponse))
        )
    }

    func testAuthorizationUpdateUsesNestedTDLibState() throws {
        let update = SyntheticFixtures.authUpdate("authorizationStateReady")
        let state = try TDLibMapper.authorizationStateObject(from: update)
        XCTAssertEqual(try TDLibMapper.authState(from: state), .authenticated)
        XCTAssertTrue(TDLibMapper.isAuthorizationClosed(SyntheticFixtures.encoded(
            SyntheticFixtures.authUpdate("authorizationStateClosed")
        )))
    }

    func testAccountMasksPhoneAndPrefersActiveUsername() throws {
        let account = try TDLibMapper.account(from: SyntheticFixtures.user())
        XCTAssertEqual(account.id, Int64(Int.max))
        XCTAssertEqual(account.displayName, "Synthetic User")
        XCTAssertEqual(account.username, "synthetic_user")
        XCTAssertEqual(account.maskedPhoneNumber, String(repeating: "•", count: 8) + String(repeating: "0", count: 4))
        XCTAssertFalse(account.maskedPhoneNumber.contains(SyntheticFixtures.phoneNumber))
    }

    func testAccountSupportsLegacyUsername() throws {
        var user = SyntheticFixtures.user()
        user.removeValue(forKey: "usernames")
        user["username"] = "legacy_synthetic"
        XCTAssertEqual(try TDLibMapper.account(from: user).username, "legacy_synthetic")
    }

    func testChatKindsCoverPinnedChatTypes() throws {
        let cases: [([String: Any], TelegramChatKind)] = [
            (["@type": "chatTypePrivate", "user_id": "1"], .user),
            (["@type": "chatTypeSecret", "secret_chat_id": 1], .user),
            (["@type": "chatTypeBasicGroup", "basic_group_id": 1], .group),
            (["@type": "chatTypeSupergroup", "supergroup_id": 1, "is_channel": false], .group),
            (["@type": "chatTypeSupergroup", "supergroup_id": 1, "is_channel": true], .channel)
        ]
        for (type, expected) in cases {
            let chat = try TDLibMapper.chat(from: SyntheticFixtures.chat(id: 1, title: "Synthetic", type: type))
            XCTAssertEqual(chat.kind, expected)
        }
    }

    func testAudioPageFiltersSortsLimitsAndPreservesMetadata() throws {
        let chatID = -Int64(String(repeating: "1", count: 6))!
        let messages: [Any] = [
            SyntheticFixtures.audioMessage(id: 10, chatID: chatID),
            SyntheticFixtures.audioMessage(id: 20, chatID: chatID),
            SyntheticFixtures.audioMessage(id: 20, chatID: chatID, fileID: 92),
            SyntheticFixtures.audioMessage(id: 15, chatID: chatID),
            SyntheticFixtures.textMessage(id: 12, chatID: chatID),
            SyntheticFixtures.audioMessage(id: 9, chatID: chatID)
        ]
        let request = try TelegramAudioPageRequest(chatID: chatID, beforeMessageID: nil, limit: 2)
        let page = try TDLibMapper.page(messages: messages, request: request)
        XCTAssertEqual(page.messages.map(\.messageID), [20, 15])
        XCTAssertEqual(page.nextCursor, 15)
        let audio = page.messages[0]
        XCTAssertEqual(audio.chatID, chatID)
        XCTAssertEqual(audio.fileID, 91)
        XCTAssertEqual(audio.fileReference, "synthetic-file-reference")
        XCTAssertEqual(audio.title, "Synthetic title")
        XCTAssertEqual(audio.performer, "Synthetic performer")
        XCTAssertEqual(audio.duration, 42)
        XCTAssertEqual(audio.fileSize, 12)
        XCTAssertEqual(audio.mimeType, "audio/mpeg")
    }

    func testAudioPageRejectsMessagesFromAnotherChat() throws {
        let request = try TelegramAudioPageRequest(chatID: 1, beforeMessageID: nil, limit: 10)
        let messages = [SyntheticFixtures.audioMessage(id: 10, chatID: 2)]
        XCTAssertThrowsError(try TDLibMapper.page(messages: messages, request: request)) { error in
            XCTAssertEqual(error as? DomainError, .telegram(.invalidResponse))
        }
        XCTAssertThrowsError(try TDLibMapper.oldestMessageID(
            messages: messages,
            chatID: 1,
            beforeMessageID: nil
        )) { error in
            XCTAssertEqual(error as? DomainError, .telegram(.invalidResponse))
        }
    }

    func testAudioPageEnforcesBackwardCursor() throws {
        let request = try TelegramAudioPageRequest(chatID: 1, beforeMessageID: 16, limit: 10)
        let page = try TDLibMapper.page(
            messages: [
                SyntheticFixtures.audioMessage(id: 20, chatID: 1),
                SyntheticFixtures.audioMessage(id: 16, chatID: 1),
                SyntheticFixtures.audioMessage(id: 15, chatID: 1),
                SyntheticFixtures.audioMessage(id: 10, chatID: 1)
            ],
            request: request
        )
        XCTAssertEqual(page.messages.map(\.messageID), [15, 10])
        XCTAssertEqual(page.nextCursor, 10)
    }

    func testOldestMessageIDUsesSameChatAndBackwardCursor() throws {
        let oldest = try TDLibMapper.oldestMessageID(
            messages: [
                SyntheticFixtures.textMessage(id: 20, chatID: 1),
                SyntheticFixtures.audioMessage(id: 10, chatID: 1),
                SyntheticFixtures.textMessage(id: 30, chatID: 1),
                SyntheticFixtures.audioMessage(id: 25, chatID: 1)
            ],
            chatID: 1,
            beforeMessageID: 21
        )
        XCTAssertEqual(oldest, 10)
    }

    func testAudioPageRejectsInvalidMetadataThroughMusicCore() {
        let request = try TelegramAudioPageRequest(chatID: 1, beforeMessageID: nil, limit: 10)
        XCTAssertThrowsError(try TDLibMapper.page(
            messages: [SyntheticFixtures.audioMessage(id: 1, chatID: 1, size: -1)],
            request: request
        )) { error in
            XCTAssertEqual(error as? DomainError, .invalidFileSize)
        }
    }

    func testStringEncodedIDsAndBooleansAreNotInterchangeable() throws {
        let object = try TDLibJSON.object(from: SyntheticFixtures.encoded(["id": String(Int64(Int.max))]))
        XCTAssertEqual(try TDLibJSON.int64(object["id"]), Int64(Int.max))
        let boolObject = try TDLibJSON.object(from: SyntheticFixtures.encoded(["id": true]))
        XCTAssertThrowsError(try TDLibJSON.int64(boolObject["id"])) { error in
            XCTAssertEqual(error as? DomainError, .telegram(.invalidResponse))
        }
    }

    func testIntegerFieldsRejectFractionalAndOutOfRangeNumbers() throws {
        for value in [1.5, Double(Int64.max) * 2] {
            let object = try TDLibJSON.object(from: SyntheticFixtures.encoded(["id": value]))
            XCTAssertThrowsError(try TDLibJSON.int64(object["id"])) { error in
                XCTAssertEqual(error as? DomainError, .telegram(.invalidResponse))
            }
        }
    }

    func testProgressUsesExpectedSizeAndClampsToKnownTotal() throws {
        var object = SyntheticFixtures.file(size: 0, downloaded: 20)
        object["expected_size"] = 12
        XCTAssertEqual(try TDLibMapper.progress(from: object), DownloadProgress(totalBytes: 12, completedBytes: 12))
        let unknown = SyntheticFixtures.file(size: 0, downloaded: 3)
        XCTAssertEqual(try TDLibMapper.progress(from: unknown), DownloadProgress(totalBytes: nil, completedBytes: 3))
        let file = try TDLibMapper.file(from: SyntheticFixtures.file(size: 12, downloaded: 20))
        XCTAssertEqual(
            try TDLibMapper.progress(file: file, knownTotal: 10),
            DownloadProgress(totalBytes: 10, completedBytes: 10)
        )
    }

    func testErrorCodesMapWithoutIncludingTDLibMessages() throws {
        XCTAssertEqual(TDLibMapper.error(code: 401), .unauthenticated)
        XCTAssertEqual(TDLibMapper.error(code: 429), .telegram(.rateLimited))
        XCTAssertEqual(TDLibMapper.error(code: 500), .telegram(.serviceUnavailable))
        XCTAssertEqual(TDLibMapper.error(code: 404), .telegram(.invalidResponse))
    }

    func testDownloadExtensionsAreAllowlisted() {
        XCTAssertEqual(DownloadFileNaming.fileExtension(forMimeType: "audio/mpeg"), ".mp3")
        XCTAssertEqual(DownloadFileNaming.fileExtension(forMimeType: "audio/mp4"), ".m4a")
        XCTAssertEqual(DownloadFileNaming.fileExtension(forMimeType: "text/plain"), "")
        XCTAssertEqual(DownloadFileNaming.sanitizedExtension("../../outside"), "")
        XCTAssertEqual(DownloadFileNaming.sanitizedExtension(".mp3"), ".mp3")
    }
}
