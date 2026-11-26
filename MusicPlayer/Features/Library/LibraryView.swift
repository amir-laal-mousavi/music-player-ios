import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let environment: AppEnvironment
    @Bindable var model: LibraryViewModel
    @Bindable var importModel: FileImportViewModel

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    importModel.isShowingPicker = true
                } label: {
                    Label("Import files", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("library.importFiles")
                .disabled(importModel.isImporting)
            }
        }
        .fileImporter(
            isPresented: $importModel.isShowingPicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importModel.importFiles(urls)
            case .failure(let error):
                importModel.reportPickerFailure(error)
            }
        }
        .task { await model.start() }
        .overlay(alignment: .bottom) {
            if let errorMessage = model.errorMessage {
                StatusBanner(kind: .error, message: errorMessage)
                    .padding()
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = importModel.errorMessage {
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
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label("Your library is empty", systemImage: "music.note")
            } description: {
                Text("Import audio files from the Files app, or sign in to Telegram and pick songs from a chat. Everything stays on this device and plays offline.")
            }

            Button {
                importModel.isShowingPicker = true
            } label: {
                Label("Import files", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .accessibilityIdentifier("library.importFiles.empty")
            .padding(.horizontal, 40)
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
