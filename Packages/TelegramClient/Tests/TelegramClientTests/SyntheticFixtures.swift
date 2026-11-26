import Foundation
import MusicCore
import XCTest
@testable import TelegramClient

internal enum SyntheticFixtures {
    static let apiHash = "synthetic-api-hash-placeholder"

    static var phoneNumber: String {
        String(repeating: "9", count: 8) + String(repeating: "0", count: 4)
    }

    static var password: String {
        String(repeating: "x", count: 12)
    }

    static func user() -> [String: Any] {
        [
            "@type": "user",
            "id": String(Int64(Int.max)),
            "first_name": "Synthetic",
            "last_name": "User",
            "phone_number": phoneNumber,
            "usernames": ["active_usernames": ["synthetic_user"]]
        ]
    }

    static func chat(id: Int64, title: String, type: [String: Any]) -> [String: Any] {
        ["@type": "chat", "id": String(id), "title": title, "type": type]
    }

    static func file(
        id: Int32 = 91,
        size: Int64 = 12,
        path: String = "",
        completed: Bool = false,
        active: Bool? = nil,
        downloaded: Int64 = 0
    ) -> [String: Any] {
        [
            "id": id,
            "size": size,
            "expected_size": size,
            "local": [
                "path": path,
                "can_be_downloaded": true,
                "can_be_deleted": true,
                "is_downloading_active": active ?? !completed,
                "is_downloading_completed": completed,
                "download_offset": 0,
                "downloaded_prefix_size": downloaded,
                "downloaded_size": downloaded
            ],
            "remote": [
                "id": "synthetic-file-reference",
                "unique_id": "synthetic-unique-id"
            ]
        ]
    }

    static func audioMessage(
        id: Int64,
        chatID: Int64,
        fileID: Int32 = 91,
        size: Int64 = 12,
        mimeType: String = "audio/mpeg"
    ) -> [String: Any] {
        [
            "@type": "message",
            "id": String(id),
            "chat_id": String(chatID),
            "content": [
                "@type": "messageAudio",
                "audio": [
                    "duration": 42,
                    "title": "Synthetic title",
                    "performer": "Synthetic performer",
                    "file_name": "../../must-not-be-a-path",
                    "mime_type": mimeType,
                    "audio": file(id: fileID, size: size)
                ],
                "caption": ""
            ]
        ]
    }

    static func textMessage(id: Int64, chatID: Int64) -> [String: Any] {
        [
            "@type": "message",
            "id": String(id),
            "chat_id": String(chatID),
            "content": ["@type": "messageText", "text": ["@type": "formattedText", "text": "synthetic"]]
        ]
    }

    static func auth(_ type: String) -> [String: Any] {
        ["@type": type]
    }

    static func authUpdate(_ type: String) -> [String: Any] {
        [
            "@type": "updateAuthorizationState",
            "authorization_state": auth(type)
        ]
    }

    static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

internal func assertDomainError<T>(
    _ expected: DomainError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as DomainError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), received \(error)", file: file, line: line)
    }
}
