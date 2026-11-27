import MusicCore
import SwiftUI

/// The search tab. The system shows it as the separate search button at the
/// trailing end of the tab bar and turns the bar into the search field.
struct LibrarySearchView: View {
    @Bindable var model: LibraryViewModel
    let onPlay: (NowPlayingRequest) -> Void

    var body: some View {
        Group {
            if !model.isSearching {
                ContentUnavailableView {
                    Label("Search your library", systemImage: "magnifyingglass")
                } description: {
                    Text("Find songs by title, artist, or chat.")
                }
            } else if model.searchResults.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                results
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: "Search songs")
        .task { await model.start() }
    }

    private var results: some View {
        List {
            Section {
                ForEach(model.searchResults) { track in
                    Button {
                        play(track)
                    } label: {
                        TrackRowView(track: track)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search.row.\(track.telegramIdentity.messageID)")
                }
            } header: {
                SectionHeading(
                    title: Format.count(model.searchResults.count, singular: "song", plural: "songs")
                )
            }
        }
        .listStyle(.plain)
    }

    private func play(_ track: Track) {
        let queue = model.searchResults
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        onPlay(NowPlayingRequest(tracks: queue, startingIndex: index))
    }
}
