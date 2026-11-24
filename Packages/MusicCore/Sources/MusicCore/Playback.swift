import Foundation

public enum PlaybackInterruptionReason: String, Sendable, Equatable {
    case audioSession
    case routeChange
}

public enum PlaybackStatus: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case interrupted(PlaybackInterruptionReason)
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
        case .playing, .paused, .interrupted:
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

public struct PlaybackQueue: Sendable, Equatable {
    public let tracks: [Track]
    public let currentIndex: Int

    public var currentTrack: Track { tracks[currentIndex] }
    public var hasPrevious: Bool { currentIndex > 0 }
    public var hasNext: Bool { currentIndex + 1 < tracks.count }

    public init(tracks: [Track], currentIndex: Int = 0) throws {
        guard !tracks.isEmpty,
              Set(tracks.map(\.id)).count == tracks.count,
              currentIndex >= 0,
              currentIndex < tracks.count else {
            throw DomainError.invalidPlaybackQueue
        }
        self.tracks = tracks
        self.currentIndex = currentIndex
    }

    public func previous() throws -> PlaybackQueue {
        guard hasPrevious else { throw DomainError.playback(.queueBoundary) }
        return PlaybackQueue(uncheckedTracks: tracks, currentIndex: currentIndex - 1)
    }

    public func next() throws -> PlaybackQueue {
        guard hasNext else { throw DomainError.playback(.queueBoundary) }
        return PlaybackQueue(uncheckedTracks: tracks, currentIndex: currentIndex + 1)
    }

    private init(uncheckedTracks: [Track], currentIndex: Int) {
        tracks = uncheckedTracks
        self.currentIndex = currentIndex
    }
}
