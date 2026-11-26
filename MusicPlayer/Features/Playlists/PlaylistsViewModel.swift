import Foundation
import MusicCore
import MusicLibrary
import Observation

@MainActor
@Observable
final class PlaylistsViewModel {
    private let store: any LibraryStore
    private var observation: Task<Void, Never>?

    var playlists: [Playlist] = []
    var errorMessage: String?
    var isLoaded = false

    init(store: any LibraryStore) {
        self.store = store
    }

    func start() async {
        guard observation == nil else { return }
        let store = self.store
        observation = Task { [weak self] in
            for await snapshot in store.observePlaylists() {
                guard let self else { return }
                self.playlists = snapshot
                self.isLoaded = true
            }
        }
        do {
            playlists = try await store.playlists()
        } catch {
            errorMessage = userMessage(for: error)
        }
        isLoaded = true
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    func create(named name: String) async {
        errorMessage = nil
        do {
            _ = try await store.createPlaylist(name: name)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func delete(_ playlist: Playlist) async {
        errorMessage = nil
        do {
            try await store.deletePlaylist(id: playlist.id)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func add(_ track: Track, to playlist: Playlist) async {
        errorMessage = nil
        do {
            try await store.addTracks([track.id], toPlaylist: playlist.id)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func remove(_ track: Track, from playlist: Playlist) async {
        errorMessage = nil
        do {
            try await store.removeTrack(track.id, fromPlaylist: playlist.id)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    /// Resolves the playlist's stored identifiers into live tracks.
    func tracks(in playlist: Playlist) async -> [Track] {
        var result: [Track] = []
        for id in playlist.trackIDs {
            if let track = try? await store.track(id: id) {
                result.append(track)
            }
        }
        return result
    }
}
