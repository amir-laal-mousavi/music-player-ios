import Foundation
import MusicCore
import Observation

@MainActor
@Observable
final class NowPlayingViewModel {
    private let player: any PlayerEngine
    private var observation: Task<Void, Never>?

    let tracks: [Track]
    let startingIndex: Int

    var state: PlaybackState = .idle
    var scrubPosition: Double = 0
    var isScrubbing = false
    var errorMessage: String?
    var hasStarted = false

    init(player: any PlayerEngine, tracks: [Track], startingIndex: Int) {
        self.player = player
        self.tracks = tracks
        self.startingIndex = startingIndex
    }

    var currentTrack: Track? {
        if let id = state.currentTrackID, let match = tracks.first(where: { $0.id == id }) {
            return match
        }
        guard tracks.indices.contains(startingIndex) else { return nil }
        return tracks[startingIndex]
    }

    var currentIndex: Int? {
        guard let id = currentTrack?.id else { return nil }
        return tracks.firstIndex(where: { $0.id == id })
    }

    var duration: TimeInterval {
        let value = state.duration
        if value > 0 { return value }
        return currentTrack?.duration ?? 0
    }

    var position: TimeInterval {
        isScrubbing ? scrubPosition : state.position
    }

    var isPlaying: Bool {
        state.status == .playing || state.status == .loading
    }

    var isPaused: Bool {
        switch state.status {
        case .paused, .interrupted(_), .completed:
            return true
        default:
            return false
        }
    }

    /// Seeking is only offered while the player holds a loaded queue.
    var canSeek: Bool {
        switch state.status {
        case .playing, .paused, .completed, .interrupted(_):
            return true
        case .idle, .loading, .failed:
            return false
        }
    }

    var canGoNext: Bool {
        guard let index = currentIndex else { return false }
        return index + 1 < tracks.count
    }

    var canGoPrevious: Bool {
        guard let index = currentIndex else { return false }
        return index > 0
    }

    var queueLabel: String? {
        guard let index = currentIndex, tracks.count > 1 else { return nil }
        return "Track \(index + 1) of \(tracks.count)"
    }

    var timeLabel: String {
        "\(Format.duration(position)) / \(Format.duration(duration))"
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let player = self.player
        observation = Task { [weak self] in
            for await next in player.observeState() {
                guard let self else { return }
                self.apply(next)
            }
        }
        await loadIfNeeded()
        apply(await player.state)
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    func togglePlayback() async {
        errorMessage = nil
        do {
            switch state.status {
            case .playing, .loading:
                try await player.pause()
            case .paused, .interrupted(_):
                try await player.resume()
            case .idle, .completed, .failed:
                try await player.play(tracks, startingAt: startingIndex)
            }
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func next() async {
        guard canGoNext else { return }
        errorMessage = nil
        do {
            try await player.next()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func previous() async {
        guard canGoPrevious else { return }
        errorMessage = nil
        do {
            try await player.previous()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func commitSeek() async {
        let target = min(max(scrubPosition, 0), max(duration, 0))
        errorMessage = nil
        do {
            try await player.seek(to: target)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func loadIfNeeded() async {
        guard tracks.indices.contains(startingIndex) else { return }
        let desired = tracks[startingIndex].id
        let current = await player.state
        guard current.currentTrackID != desired else { return }
        do {
            try await player.play(tracks, startingAt: startingIndex)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func apply(_ next: PlaybackState) {
        state = next
        if !isScrubbing {
            scrubPosition = next.position
        }
        if let error = next.error {
            errorMessage = error.userMessage
        }
    }
}
