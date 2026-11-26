import Foundation
import MusicCore
import MusicLibrary
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    private let store: any LibraryStore
    private let coordinator: ImportCoordinator
    private let player: any PlayerEngine
    private var observation: Task<Void, Never>?

    var tracks: [Track] = []
    var query = ""
    var hasLoaded = false
    var errorMessage: String?
    var isDeleting = false

    init(store: any LibraryStore, coordinator: ImportCoordinator, player: any PlayerEngine) {
        self.store = store
        self.coordinator = coordinator
        self.player = player
    }

    var filteredTracks: [Track] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tracks }
        return tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(needle)
                || track.artist.localizedCaseInsensitiveContains(needle)
                || track.sourceChat.title.localizedCaseInsensitiveContains(needle)
        }
    }

    var isEmpty: Bool { hasLoaded && tracks.isEmpty }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    func start() async {
        let store = self.store
        observation = Task { [weak self] in
            for await snapshot in store.observeTracks() {
                guard let self else { return }
                self.update(tracks: snapshot)
            }
        }
        do {
            update(tracks: try await store.tracks())
        } catch {
            errorMessage = userMessage(for: error)
            hasLoaded = true
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Keeps the view in sync with store snapshots; also the seam used by tests.
    func update(tracks: [Track]) {
        self.tracks = tracks
        hasLoaded = true
    }

    func delete(_ track: Track) async {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        do {
            try await coordinator.deleteTrack(id: track.id)
            if await playerTrackIDMatches(track.id) {
                try? await player.stop()
            }
        } catch {
            errorMessage = userMessage(for: error)
        }
        isDeleting = false
    }

    func playbackRequest(for track: Track) -> NowPlayingRequest? {
        let queue = filteredTracks
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return nil }
        return NowPlayingRequest(tracks: queue, startingIndex: index)
    }

    private func playerTrackIDMatches(_ id: Track.ID) async -> Bool {
        await player.state.currentTrackID == id
    }
}
