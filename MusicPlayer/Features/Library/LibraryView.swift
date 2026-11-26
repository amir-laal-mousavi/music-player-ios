import MusicCore
import SwiftUI

struct LibraryView: View {
    let environment: AppEnvironment
    @Bindable var model: LibraryViewModel

    @State private var nowPlaying: NowPlayingViewModel?
    @State private var pendingDeletion: Track?

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView("Opening library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tracks.isEmpty {
                emptyLibrary
            } else if model.filteredTracks.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                trackList
            }
        }
        .navigationTitle("Library")
        .searchable(text: $model.query, prompt: "Search songs")
        .musicBarBackground()
        .task { await model.start() }
        .overlay(alignment: .bottom) {
            if let errorMessage = model.errorMessage {
                StatusBanner(kind: .error, message: errorMessage)
                    .padding()
            }
        }
        .sheet(isPresented: isShowingPlayer) {
            if let nowPlaying {
                NowPlayingView(model: nowPlaying)
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = track
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
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
            Text("Sign in to Telegram, pick a chat, and select the songs you want. They stay on this device and play offline.")
        }
    }

    private func play(_ track: Track) {
        guard let request = model.playbackRequest(for: track) else { return }
        nowPlaying = NowPlayingViewModel(
            player: environment.player,
            tracks: request.tracks,
            startingIndex: request.startingIndex
        )
    }

    private func displayTitle(_ track: Track) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "This audio" : "“\(title)”"
    }

    private var isShowingPlayer: Binding<Bool> {
        Binding(
            get: { nowPlaying != nil },
            set: { isPresented in
                if !isPresented { nowPlaying = nil }
            }
        )
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
