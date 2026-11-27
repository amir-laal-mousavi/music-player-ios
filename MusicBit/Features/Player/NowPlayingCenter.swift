import Foundation
import MediaPlayer
import MusicCore
import UIKit

/// Publishes the current track to the lock screen, Control Center and CarPlay,
/// and routes their remote commands back to the player.
@MainActor
final class NowPlayingCenter {
    struct Commands {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        let next: () -> Void
        let previous: () -> Void
        let seek: (TimeInterval) -> Void
    }

    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()

    private var commands: Commands?
    private var lastTrackID: Track.ID?
    private var lastWasPlaying: Bool?
    private var lastPosition: TimeInterval = 0
    private var cachedArtwork: (url: URL, artwork: MPMediaItemArtwork)?

    /// Registers the remote commands once; repeated calls replace the handlers.
    func activate(_ commands: Commands) {
        self.commands = commands
        let center = commandCenter

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.commands?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in self?.commands?.seek(position) }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
    }

    /// Updates the lock screen only when the track, play state, or a paused
    /// position changed. While playing the system extrapolates the elapsed time.
    func update(track: Track?, position: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let track else {
            clear()
            return
        }

        let trackChanged = track.id != lastTrackID
        let playStateChanged = isPlaying != lastWasPlaying
        let movedWhilePaused = !isPlaying && abs(position - lastPosition) >= 1
        // A jump while playing means a seek, which the system cannot extrapolate.
        let jumped = abs(position - lastPosition) >= 3
        guard trackChanged || playStateChanged || movedWhilePaused || jumped else { return }

        lastTrackID = track.id
        lastWasPlaying = isPlaying
        lastPosition = position

        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Untitled audio" : title,
            MPMediaItemPropertyArtist: artist.isEmpty ? "Unknown artist" : artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = artwork(for: track.artworkURL) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        lastTrackID = nil
        lastWasPlaying = nil
        lastPosition = 0
        infoCenter.nowPlayingInfo = nil
    }

    private func artwork(for url: URL?) -> MPMediaItemArtwork? {
        guard let url else { return nil }
        if let cached = cachedArtwork, cached.url == url { return cached.artwork }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (url, artwork)
        return artwork
    }
}
