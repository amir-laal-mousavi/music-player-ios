import CoreFoundation
import Foundation
import MusicCore

internal enum TDLibJSON {
    static let invalidResponse = DomainError.telegram(.invalidResponse)

    static func object(from data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw invalidResponse
        }
        return object
    }

    static func type(of data: Data) -> String? {
        guard let object = try? object(from: data) else { return nil }
        return object["@type"] as? String
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw invalidResponse
        }
    }

    static func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw invalidResponse }
        return object
    }

    static func optionalObject(_ value: Any?) throws -> [String: Any]? {
        guard value != nil, !(value is NSNull) else { return nil }
        return try object(value)
    }

    static func array(_ value: Any?) throws -> [Any] {
        guard let array = value as? [Any] else { throw invalidResponse }
        return array
    }

    static func string(_ value: Any?) throws -> String {
        guard let string = value as? String else { throw invalidResponse }
        return string
    }

    static func optionalString(_ value: Any?) throws -> String? {
        guard value != nil, !(value is NSNull) else { return nil }
        return try string(value)
    }

    static func bool(_ value: Any?) throws -> Bool {
        guard let bool = value as? Bool else { throw invalidResponse }
        return bool
    }

    static func int64(_ value: Any?) throws -> Int64 {
        if let string = value as? String {
            guard let integer = Int64(string) else { throw invalidResponse }
            return integer
        }
        if let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() {
            guard let integer = Int64(exactly: number.doubleValue) else { throw invalidResponse }
            return integer
        }
        throw invalidResponse
    }

    static func int32(_ value: Any?) throws -> Int32 {
        guard let integer = Int32(exactly: try int64(value)) else { throw invalidResponse }
        return integer
    }
}

internal struct TDLibFile: Sendable {
    let id: Int32
    let size: Int64
    let expectedSize: Int64
    let localPath: String
    let isCompleted: Bool
    let isDownloadingActive: Bool
    let downloadedSize: Int64
}

internal enum TDLibMapper {
    static func authorizationStateObject(from update: [String: Any]) throws -> [String: Any] {
        guard try TDLibJSON.string(update["@type"]) == "updateAuthorizationState" else {
            throw TDLibJSON.invalidResponse
        }
        return try TDLibJSON.object(update["authorization_state"])
    }

    static func isAuthorizationClosed(_ data: Data) -> Bool {
        guard let update = try? TDLibJSON.object(from: data),
              let state = try? authorizationStateObject(from: update) else {
            return false
        }
        return (try? TDLibJSON.string(state["@type"])) == "authorizationStateClosed"
    }

    static func authState(from object: [String: Any]) throws -> TelegramAuthState {
        switch try TDLibJSON.string(object["@type"]) {
        case "authorizationStateWaitTdlibParameters", "authorizationStateClosed":
            return .unauthenticated
        case "authorizationStateWaitPhoneNumber":
            return .waitingForPhone
        case "authorizationStateWaitCode":
            return .waitingForCode
        case "authorizationStateWaitPassword":
            return .waitingForPassword
        case "authorizationStateReady":
            return .authenticated
        case "authorizationStateLoggingOut", "authorizationStateClosing":
            return .loggingOut
        default:
            return .failure(.telegram(.invalidResponse))
        }
    }

    static func account(from object: [String: Any]) throws -> TelegramAccount {
        let firstName = try TDLibJSON.string(object["first_name"])
        let lastName = try TDLibJSON.string(object["last_name"])
        let displayName = [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var username: String?
        if let usernames = try TDLibJSON.optionalObject(object["usernames"]) {
            let active = try TDLibJSON.array(usernames["active_usernames"])
            if let first = active.first {
                username = try TDLibJSON.string(first)
            }
        } else if let legacyUsername = try TDLibJSON.optionalString(object["username"]),
                  !legacyUsername.isEmpty {
            username = legacyUsername
        }
        return try TelegramAccount(
            id: try TDLibJSON.int64(object["id"]),
            displayName: displayName,
            phoneNumber: try TDLibJSON.string(object["phone_number"]),
            username: username
        )
    }

    static func chat(from object: [String: Any]) throws -> TelegramChat {
        let type = try TDLibJSON.object(object["type"])
        let kind: TelegramChatKind
        switch try TDLibJSON.string(type["@type"]) {
        case "chatTypePrivate", "chatTypeSecret":
            kind = .user
        case "chatTypeBasicGroup":
            kind = .group
        case "chatTypeSupergroup":
            kind = try TDLibJSON.bool(type["is_channel"]) ? .channel : .group
        default:
            throw TDLibJSON.invalidResponse
        }
        return try TelegramChat(
            id: try TDLibJSON.int64(object["id"]),
            title: try TDLibJSON.string(object["title"]),
            kind: kind
        )
    }

    static func page(messages: [Any], request: TelegramAudioPageRequest) throws -> TelegramAudioPage {
        var audios: [TelegramAudio] = []
        var seenMessageIDs = Set<Int64>()
        for value in messages {
            guard !(value is NSNull) else { continue }
            let message = try TDLibJSON.object(value)
            let messageChatID = try TDLibJSON.int64(message["chat_id"])
            guard messageChatID == request.chatID else { throw TDLibJSON.invalidResponse }
            let messageID = try TDLibJSON.int64(message["id"])
            guard messageID > 0,
                  seenMessageIDs.insert(messageID).inserted,
                  request.beforeMessageID.map({ messageID < $0 }) ?? true else {
                continue
            }
            let content = try TDLibJSON.object(message["content"])
            guard try TDLibJSON.string(content["@type"]) == "messageAudio" else { continue }
            audios.append(try audio(from: content["audio"], messageID: messageID, chatID: request.chatID))
        }
        audios.sort { $0.messageID > $1.messageID }
        let limited = Array(audios.prefix(request.limit))
        return try TelegramAudioPage(
            chatID: request.chatID,
            messages: limited,
            nextCursor: limited.last?.messageID
        )
    }

    static func oldestMessageID(
        messages: [Any],
        chatID: TelegramChat.ID,
        beforeMessageID: Int64?
    ) throws -> Int64? {
        var oldest: Int64?
        for value in messages {
            guard !(value is NSNull) else { continue }
            let message = try TDLibJSON.object(value)
            guard try TDLibJSON.int64(message["chat_id"]) == chatID else {
                throw TDLibJSON.invalidResponse
            }
            let id = try TDLibJSON.int64(message["id"])
            guard id > 0, beforeMessageID.map({ id < $0 }) ?? true else { continue }
            oldest = min(oldest ?? id, id)
        }
        return oldest
    }

    static func progress(from object: [String: Any]) throws -> DownloadProgress {
        try progress(file: file(from: object))
    }

    static func progress(file: TDLibFile, knownTotal: Int64? = nil) throws -> DownloadProgress {
        let total = knownTotal.flatMap { $0 > 0 ? $0 : nil }
            ?? (file.size > 0 ? file.size : (file.expectedSize > 0 ? file.expectedSize : nil))
        var completed = max(0, file.downloadedSize)
        if let total {
            completed = min(completed, total)
        }
        return try DownloadProgress(totalBytes: total, completedBytes: completed)
    }

    static func file(from object: [String: Any]) throws -> TDLibFile {
        let local = try TDLibJSON.object(object["local"])
        let size = try TDLibJSON.int64(object["size"])
        let expectedSize = try TDLibJSON.int64(object["expected_size"])
        let downloadedSize = try TDLibJSON.int64(local["downloaded_size"])
        guard size >= 0, expectedSize >= 0, downloadedSize >= 0 else {
            throw TDLibJSON.invalidResponse
        }
        return TDLibFile(
            id: try TDLibJSON.int32(object["id"]),
            size: size,
            expectedSize: expectedSize,
            localPath: try TDLibJSON.optionalString(local["path"]) ?? "",
            isCompleted: try TDLibJSON.bool(local["is_downloading_completed"]),
            isDownloadingActive: try TDLibJSON.bool(local["is_downloading_active"]),
            downloadedSize: downloadedSize
        )
    }

    static func requireOK(_ data: Data) throws {
        guard try TDLibJSON.string(TDLibJSON.object(from: data)["@type"]) == "ok" else {
            throw TDLibJSON.invalidResponse
        }
    }

    static func error(code: Int32) -> DomainError {
        switch code {
        case 401:
            return .unauthenticated
        case 429:
            return .telegram(.rateLimited)
        case 500...Int32.max:
            return .telegram(.serviceUnavailable)
        default:
            return .telegram(.invalidResponse)
        }
    }

    private static func audio(from value: Any?, messageID: Int64, chatID: TelegramChat.ID) throws -> TelegramAudio {
        let audio = try TDLibJSON.object(value)
        let file = try TDLibJSON.object(audio["audio"])
        let remote = try TDLibJSON.object(file["remote"])
        let size = try TDLibJSON.int64(file["size"])
        let mimeType = try TDLibJSON.optionalString(audio["mime_type"])
        var thumbnail: TelegramThumbnail?
        if let cover = try TDLibJSON.optionalObject(audio["album_cover_thumbnail"]),
           let coverFile = try TDLibJSON.optionalObject(cover["file"]),
           let fileID = try? TDLibJSON.int32(coverFile["id"]) {
            thumbnail = try? TelegramThumbnail(fileID: fileID)
        }
        return try TelegramAudio(
            identity: TelegramAudioIdentity(chatID: chatID, messageID: messageID),
            fileID: try TDLibJSON.int32(file["id"]),
            fileReference: try TDLibJSON.string(remote["id"]),
            title: try TDLibJSON.string(audio["title"]),
            performer: try TDLibJSON.string(audio["performer"]),
            duration: TimeInterval(try TDLibJSON.int64(audio["duration"])),
            fileSize: size == 0 ? nil : size,
            mimeType: mimeType?.isEmpty == false ? mimeType : nil,
            thumbnail: thumbnail
        )
    }
}
