import Foundation
import MusicCore

enum Format {
    static func duration(_ value: TimeInterval) -> String {
        guard value.isFinite, value > 0 else { return "0:00" }
        let total = Int(value.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func progressFraction(_ progress: DownloadProgress?) -> Double? {
        guard let progress else { return nil }
        if let fraction = progress.fractionCompleted { return min(max(fraction, 0), 1) }
        return progress.completedBytes > 0 ? nil : 0
    }

    static func count(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}

extension DomainError {
    var userMessage: String {
        switch self {
        case .invalidPhoneNumber:
            return "Enter a phone number in international format, for example +1 555 010 1234."
        case .invalidAuthenticationCode:
            return "Enter the code Telegram sent you."
        case .invalidPassword:
            return "Enter your Telegram two-step password."
        case .chatNotFound:
            return "That chat is no longer available."
        case .audioNotFound:
            return "That audio message is no longer available."
        case .duplicateTrack:
            return "This song is already in your library."
        case .trackNotFound:
            return "This track is no longer in your library."
        case .importJobNotFound:
            return "That import is no longer available."
        case .unauthenticated:
            return "Your Telegram session has expired. Sign in again to keep importing."
        case .telegram(let error):
            return error.userMessage
        case .library(.unavailable):
            return "The library storage is not available on this device."
        case .library(.corruptData):
            return "Some library data could not be read and was skipped."
        case .library(.writeFailed):
            return "The library could not save this file. Check the available storage and try again."
        case .playback(.fileUnavailable):
            return "This file is missing from the device. Import it again."
        case .playback(.unsupportedFormat):
            return "This audio format cannot be played on this device."
        case .playback(.notReady):
            return "The player is not ready yet."
        case .playback(.playbackFailed):
            return "Playback stopped unexpectedly."
        case .playback(.queueBoundary):
            return "There are no more tracks in this queue."
        case .invalidStateTransition:
            return "That action is not available right now. Try again."
        case .invalidPlaybackState, .invalidPlaybackQueue:
            return "The player state is inconsistent. Start the track again."
        default:
            return "Something is not valid in this request."
        }
    }

    var isOfflineRelated: Bool {
        switch self {
        case .telegram(.networkUnavailable), .telegram(.serviceUnavailable), .telegram(.rateLimited):
            return true
        default:
            return false
        }
    }

    var isAuthenticationRelated: Bool {
        switch self {
        case .unauthenticated, .telegram(.notAuthorized):
            return true
        default:
            return false
        }
    }
}

extension TelegramGatewayError {
    var userMessage: String {
        switch self {
        case .notAuthorized:
            return "Telegram needs you to sign in again."
        case .networkUnavailable:
            return "No connection to Telegram. Imported music still plays offline."
        case .rateLimited:
            return "Telegram is limiting requests. Wait a moment and try again."
        case .serviceUnavailable:
            return "Telegram is temporarily unavailable. Try again shortly."
        case .invalidResponse:
            return "Telegram sent a response the app could not read."
        case .downloadFailed:
            return "This file could not be downloaded from Telegram."
        }
    }
}

func userMessage(for error: Error) -> String {
    if let domain = error as? DomainError { return domain.userMessage }
    if let telegram = error as? TelegramGatewayError { return telegram.userMessage }
    return error.localizedDescription
}
