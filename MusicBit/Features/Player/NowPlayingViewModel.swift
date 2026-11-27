import Foundation
import MusicCore
import Observation

@MainActor
@Observable
final class NowPlayingViewModel {
    private let player: any PlayerEngine
    private let nowPlaying = NowPlayingCenter()
    private var observation: Task<Void, Never>?

    private(set) var tracks: [Track]
    private(set) var startingIndex: Int

    var state: PlaybackState = .idle
    var scrubPosition: Double = 0
    var isScrubbing = false
    var errorMessage: String?
    var hasStarted = false
    var repeatMode: RepeatMode = .off
    var isShuffled = false

    init(player: any PlayerEngine, tracks: [Track], startingIndex: Int) {
        self.player = player
        self.tracks = tracks
        self.startingIndex = startingIndex
    }

    var currentTrack: Track? {
        if let id = state.currentTrackID, let match = tracks.first(where: { $0.id == id }) {
            return match
        }
        // The fallback only applies once playback has actually been asked for.
        guard state.status != .idle, tracks.indices.contains(startingIndex) else { return nil }
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
        tracks.count > 1 || repeatMode == .all
    }

    var canGoPrevious: Bool {
        tracks.count > 1 || repeatMode == .all
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
        activateRemoteCommands()
        await loadIfNeeded()
        apply(await player.state)
        repeatMode = await player.repeatMode
        isShuffled = await player.isShuffled
    }

    func stop() {
        observation?.cancel()
        observation = nil
        nowPlaying.clear()
    }

    /// Lock screen, Control Center and headphone controls drive the same actions
    /// as the in-app player, so their state can never drift apart.
    private func activateRemoteCommands() {
        nowPlaying.activate(
            NowPlayingCenter.Commands(
                play: { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.isPlaying else { return }
                        await self.togglePlayback()
                    }
                },
                pause: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.isPlaying else { return }
                        await self.togglePlayback()
                    }
                },
                toggle: { [weak self] in
                    Task { @MainActor in
                        await self?.togglePlayback()
                    }
                },
                next: { [weak self] in
                    Task { @MainActor in
                        await self?.next()
                    }
                },
                previous: { [weak self] in
                    Task { @MainActor in
                        await self?.previous()
                    }
                },
                seek: { [weak self] position in
                    Task { @MainActor in
                        guard let self else { return }
                        self.scrubPosition = position
                        await self.commitSeek()
                    }
                }
            )
        )
    }

    /// Replaces the queue from anywhere in the app and starts playing it.
    func load(_ newTracks: [Track], startingAt index: Int) async {
        guard newTracks.indices.contains(index) else { return }
        tracks = newTracks
        startingIndex = index
        errorMessage = nil
        if !hasStarted {
            await start()
        }
        do {
            try await player.play(newTracks, startingAt: index)
            state = await player.state
            repeatMode = await player.repeatMode
            isShuffled = await player.isShuffled
            syncNowPlaying()
        } catch {
            errorMessage = userMessage(for: error)
        }
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
        } catch let error as DomainError {
            if case .playback(.queueBoundary) = error { return }
            errorMessage = userMessage(for: error)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    /// Small relative jump used by press-and-hold fast-forward/rewind.
    func skip(by seconds: TimeInterval) async {
        guard canSeek else { return }
        let target = min(max(position + seconds, 0), max(duration, 0))
        scrubPosition = target
        errorMessage = nil
        do {
            try await player.seek(to: target)
        } catch let error as DomainError {
            if case .playback(.queueBoundary) = error { return }
            errorMessage = userMessage(for: error)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func previous() async {
        guard canGoPrevious else { return }
        errorMessage = nil
        do {
            try await player.previous()
        } catch let error as DomainError {
            if case .playback(.queueBoundary) = error { return }
            errorMessage = userMessage(for: error)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    /// off → all → one → off, like the system player.
    func cycleRepeatMode() async {
        let next = repeatMode.next
        await player.setRepeatMode(next)
        repeatMode = next
    }

    func applyEqualizer(_ settings: EqualizerSettings) async {
        await player.applyEqualizer(settings)
    }

    func toggleShuffle() async {
        let next = !isShuffled
        await player.setShuffled(next)
        isShuffled = next
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
        syncNowPlaying()
    }

    private func syncNowPlaying() {
        nowPlaying.update(
            track: currentTrack,
            position: position,
            duration: duration,
            isPlaying: state.status == .playing
        )
    }
}
