import Foundation

public enum PlaybackStatus: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case completed
    case failed
}

public struct PlaybackState: Sendable, Equatable {
    public static let idle = PlaybackState(
        status: .idle,
        currentTrackID: nil,
        position: 0,
        duration: 0,
        error: nil
    )

    public let status: PlaybackStatus
    public let currentTrackID: Track.ID?
    public let position: TimeInterval
    public let duration: TimeInterval
    public let error: DomainError?

    private init(
        status: PlaybackStatus,
        currentTrackID: Track.ID?,
        position: TimeInterval,
        duration: TimeInterval,
        error: DomainError?
    ) {
        self.status = status
        self.currentTrackID = currentTrackID
        self.position = position
        self.duration = duration
        self.error = error
    }

    public init(
        status: PlaybackStatus,
        currentTrackID: Track.ID? = nil,
        position: TimeInterval = 0,
        duration: TimeInterval = 0,
        error: DomainError? = nil
    ) throws {
        guard duration.isFinite, duration >= 0, position.isFinite, position >= 0, position <= duration else {
            throw DomainError.invalidPlaybackState
        }
        switch status {
        case .idle:
            guard currentTrackID == nil, position == 0, duration == 0, error == nil else {
                throw DomainError.invalidPlaybackState
            }
        case .loading:
            guard currentTrackID != nil, position == 0, error == nil else {
                throw DomainError.invalidPlaybackState
            }
        case .playing, .paused:
            guard currentTrackID != nil, error == nil else {
                throw DomainError.invalidPlaybackState
            }
        case .completed:
            guard currentTrackID != nil, position == duration, error == nil else {
                throw DomainError.invalidPlaybackState
            }
        case .failed:
            guard error != nil else { throw DomainError.invalidPlaybackState }
        }
        self.init(
            status: status,
            currentTrackID: currentTrackID,
            position: position,
            duration: duration,
            error: error
        )
    }
}
