import Foundation

public enum TelegramGatewayError: Error, Equatable, Sendable {
    case notAuthorized
    case networkUnavailable
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case downloadFailed
}

public enum LibraryStoreError: Error, Equatable, Sendable {
    case unavailable
    case corruptData
    case writeFailed
}

public enum PlayerError: Error, Equatable, Sendable {
    case notReady
    case fileUnavailable
    case unsupportedFormat
    case playbackFailed
    case queueBoundary
}

public enum DomainError: Error, Equatable, Sendable {
    case invalidPhoneNumber
    case invalidAuthenticationCode
    case invalidPassword
    case invalidAccountIdentifier
    case invalidAccountName
    case invalidAccountUsername
    case invalidChatIdentifier
    case invalidAudioIdentifier
    case invalidChatTitle
    case invalidFileIdentifier
    case invalidFileReference
    case invalidFileSize
    case invalidMIMEType
    case invalidDuration
    case invalidAudioPageRequest
    case invalidAudioPage
    case invalidDownloadProgress
    case invalidTrack
    case invalidImportItem
    case duplicateImportItem(TelegramAudioIdentity)
    case invalidImportJob
    case invalidPlaybackState
    case invalidPlaybackQueue
    case invalidStateTransition(from: String, to: String)
    case unauthenticated
    case chatNotFound(TelegramChat.ID)
    case audioNotFound(TelegramAudioIdentity)
    case duplicateTrack(TelegramAudioIdentity)
    case trackNotFound(Track.ID)
    case importJobNotFound(ImportJob.ID)
    case invalidPlaylist
    case invalidPlaylistName
    case invalidPlaylistTracks
    case playlistNotFound(Playlist.ID)
    case telegram(TelegramGatewayError)
    case library(LibraryStoreError)
    case playback(PlayerError)
}
