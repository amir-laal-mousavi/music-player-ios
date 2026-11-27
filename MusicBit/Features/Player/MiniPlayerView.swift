import MusicCore
import SwiftUI

/// Compact now-playing bar shown in the tab view's bottom accessory. The system
/// supplies its glass chrome; this view only lays out the content.
struct MiniPlayerView: View {
    @Bindable var model: NowPlayingViewModel
    let onOpen: () -> Void

    private var title: String {
        guard let track = model.currentTrack else { return "Nothing playing" }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled audio" : title
    }

    private var artist: String {
        guard let track = model.currentTrack else { return "" }
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? "Unknown artist" : artist
    }

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(max(model.position / model.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        ArtworkImage(
                            url: model.currentTrack?.artworkURL,
                            title: title,
                            size: 38,
                            cornerRadius: 19
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mini.open")

                Button {
                    Task { await model.togglePlayback() }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("mini.playPause")

                Button {
                    Task { await model.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 40)
                }
                .accessibilityLabel("Next track")
                .accessibilityIdentifier("mini.next")
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)

            GeometryReader { proxy in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: proxy.size.width * progress, height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini.player")
    }
}
