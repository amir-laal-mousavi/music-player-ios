import MusicCore
import SwiftUI

/// Playlists tab: every playlist, with creation, deletion and drill-in.
struct PlaylistsView: View {
    @Bindable var model: PlaylistsViewModel
    let onPlay: ([Track], Int) -> Void

    @State private var isCreating = false
    @State private var newName = ""
    @State private var pendingDeletion: Playlist?

    var body: some View {
        List {
            Section {
                Button {
                    newName = ""
                    isCreating = true
                } label: {
                    Label("New playlist", systemImage: "plus")
                }
                .accessibilityIdentifier("playlists.new")
            }

            if model.playlists.isEmpty {
                Section {
                    Text("Playlists collect songs from your library. Create one, then add songs from the library list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(model.playlists) { playlist in
                        NavigationLink(value: playlist.id) {
                            PlaylistRow(playlist: playlist)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    StatusBanner(kind: .error, message: errorMessage)
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationDestination(for: Playlist.ID.self) { id in
            PlaylistDetailView(model: model, playlistID: id, onPlay: onPlay)
        }
        .alert("New playlist", isPresented: $isCreating) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName
                Task { await model.create(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this playlist?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { playlist in
            Button("Delete", role: .destructive) {
                Task { await model.delete(playlist) }
            }
        } message: { playlist in
            Text("Songs stay in your library.")
        }
        .task { await model.start() }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
                .font(.body.weight(.semibold))
            Text(Format.count(playlist.trackIDs.count, singular: "song", plural: "songs"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Songs inside one playlist, resolved from the live library.
struct PlaylistDetailView: View {
    let model: PlaylistsViewModel
    let playlistID: Playlist.ID
    let onPlay: ([Track], Int) -> Void

    @State private var tracks: [Track] = []

    private var playlist: Playlist? {
        model.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        List {
            if tracks.isEmpty {
                Section {
                    Text("This playlist is empty. Add songs from the library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(tracks) { track in
                        Button {
                            play(startingAt: track)
                        } label: {
                            TrackRowView(track: track)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let playlist {
                                Button(role: .destructive) {
                                    Task {
                                        await model.remove(track, from: playlist)
                                        await refresh()
                                    }
                                } label: {
                                    Label("Remove", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                } header: {
                    SectionHeading(
                        title: playlist?.name ?? "Playlist",
                        subtitle: Format.count(tracks.count, singular: "song", plural: "songs")
                    )
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onPlay(tracks, 0)
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(tracks.isEmpty)
                .accessibilityLabel("Play playlist")
            }
        }
        .task(id: playlist?.trackIDs) {
            await refresh()
        }
    }

    private func play(startingAt track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        onPlay(tracks, index)
    }

    private func refresh() async {
        guard let playlist else {
            tracks = []
            return
        }
        tracks = await model.tracks(in: playlist)
    }
}

/// Small sheet used from the library list to add a song to a playlist.
struct AddToPlaylistSheet: View {
    @Bindable var model: PlaylistsViewModel
    let track: Track

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.playlists.isEmpty {
                    Section {
                        Text("Create a playlist first from the Playlists tab.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(model.playlists) { playlist in
                            Button {
                                Task {
                                    await model.add(track, to: playlist)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    PlaylistRow(playlist: playlist)
                                    Spacer()
                                    if playlist.trackIDs.contains(track.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
