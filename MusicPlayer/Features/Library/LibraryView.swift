import MusicCore
import SwiftUI

struct LibraryView: View {
    let environment: AppEnvironment
    @Bindable var model: LibraryViewModel
    @Bindable var playlists: PlaylistsViewModel
    @Binding var isSearchPresented: Bool
    let onPlay: (NowPlayingRequest) -> Void

    @State private var pendingDeletion: Track?
    @State private var trackToAdd: Track?
    @State private var isShowingPlaylists = false

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView("Opening library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tracks.isEmpty {
                emptyLibrary
            } else if model.filteredTracks.isEmpty {
                if model.showsFavoritesOnly && model.query.isEmpty {
                    ContentUnavailableView {
                        Label("No favorites yet", systemImage: "heart")
                    } description: {
                        Text("Swipe a song to the right to mark it as a favorite.")
                    }
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            } else {
                trackList
            }
        }
        .navigationTitle("Library")
        .searchable(text: $model.query, isPresented: $isSearchPresented, prompt: "Search songs")
        .musicBarBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.toggleFavoritesFilter()
                    } label: {
                        Label(
                            model.showsFavoritesOnly ? "Show all songs" : "Show favorites",
                            systemImage: model.showsFavoritesOnly ? "heart.slash" : "heart"
                        )
                    }
                    Button {
                        isShowingPlaylists = true
                    } label: {
                        Label("Playlists", systemImage: "rectangle.stack")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("library.menu")
            }
        }
        .task { await model.start() }
        .task { await playlists.start() }
        .sheet(isPresented: $isShowingPlaylists) {
            PlaylistsSheet(model: playlists, onPlay: { tracks, index in
                isShowingPlaylists = false
                onPlay(NowPlayingRequest(tracks: tracks, startingIndex: index))
            })
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistSheet(model: playlists, track: track)
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = model.errorMessage {
                StatusBanner(kind: .error, message: errorMessage)
                    .padding()
            }
        }
        .alert(
            "Remove from library?",
            isPresented: deletionBinding,
            presenting: pendingDeletion
        ) { track in
            Button("Remove", role: .destructive) {
                Task { await model.delete(track) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { track in
            Text("\(displayTitle(track)) and its downloaded file are deleted from this device. Telegram is not affected.")
        }
    }

    private var trackList: some View {
        List {
            Section {
                ForEach(model.filteredTracks) { track in
                    Button {
                        play(track)
                    } label: {
                        TrackRowView(track: track)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.row.\(track.telegramIdentity.messageID)")
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await model.toggleFavorite(track) }
                        } label: {
                            Label(
                                model.isFavorite(track) ? "Unfavorite" : "Favorite",
                                systemImage: model.isFavorite(track) ? "heart.slash.fill" : "heart.fill"
                            )
                        }
                        .tint(.pink)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = track
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        Button {
                            trackToAdd = track
                        } label: {
                            Label("Playlist", systemImage: "text.badge.plus")
                        }
                        .tint(.indigo)
                    }
                }
            } header: {
                SectionHeading(
                    title: Format.count(model.tracks.count, singular: "song", plural: "songs"),
                    subtitle: "\(Format.duration(model.totalDuration)) stored on this device"
                )
            }
        }
        .listStyle(.plain)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "music.note")
        } description: {
            Text("Use the Import tab to add audio files, or sign in to Telegram and pick songs from a chat. Everything stays on this device and plays offline.")
        }
    }

    private func play(_ track: Track) {
        guard let request = model.playbackRequest(for: track) else { return }
        onPlay(request)
    }

    private func displayTitle(_ track: Track) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "This audio" : "“\(title)”"
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingDeletion = nil }
            }
        )
    }
}
