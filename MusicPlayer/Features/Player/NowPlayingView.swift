import MusicCore
import SwiftUI
import UIKit

struct NowPlayingView: View {
    @Bindable var model: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var artworkImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                animatedBackground

                VStack(spacing: 16) {
                    Spacer(minLength: 4)
                    artwork
                    titleBlock
                    progressBlock
                    transport
                    if let errorMessage = model.errorMessage {
                        StatusBanner(kind: .error, message: errorMessage)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Close player")
                }
            }
            .task { await model.start() }
            .task(id: model.currentTrack?.artworkURL) {
                artworkImage = await ArtworkImageCache.shared.image(for: model.currentTrack?.artworkURL)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Slowly drifting colour field sampled from the cover art, Apple Music style.
    private var animatedBackground: some View {
        let palette = ArtworkPalette.colors(for: artworkImage, fallbackTitle: titleText)
        return TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(
                    colors: [palette[0], palette[1], palette[2]],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(palette[0])
                    .frame(width: 360, height: 360)
                    .blur(radius: 90)
                    .offset(x: CGFloat(cos(time * 0.17)) * 90, y: CGFloat(sin(time * 0.23)) * 110)

                Circle()
                    .fill(palette[1])
                    .frame(width: 320, height: 320)
                    .blur(radius: 100)
                    .offset(x: CGFloat(sin(time * 0.13)) * -110, y: CGFloat(cos(time * 0.19)) * 90)

                Color.black.opacity(0.22)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var artwork: some View {
        ArtworkImage(
            url: model.currentTrack?.artworkURL,
            title: titleText,
            size: 300,
            cornerRadius: 28
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(titleText)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityIdentifier("player.title")
            Text(artistText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            if let queueLabel = model.queueLabel {
                Text(queueLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 4) {
            Slider(
                value: $model.scrubPosition,
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in
                    model.isScrubbing = editing
                    if !editing {
                        Task { await model.commitSeek() }
                    }
                }
            )
            .tint(.white)
            .disabled(!model.canSeek)
            .accessibilityLabel("Playback position")
            .accessibilityIdentifier("player.scrubber")

            HStack {
                Text(Format.duration(model.position))
                Spacer()
                Text(Format.duration(model.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityHidden(true)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                Task { await model.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(model.isShuffled ? Theme.accent : Color.white.opacity(0.65))
            }
            .accessibilityLabel(model.isShuffled ? "Shuffle on" : "Shuffle off")
            .accessibilityIdentifier("player.shuffle")

            Button {
                Task { await model.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .frame(width: 48, height: 48)
            }
            .disabled(!model.canGoPrevious)
            .accessibilityLabel("Previous track")
            .accessibilityIdentifier("player.previous")

            Button {
                Task { await model.togglePlayback() }
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(Theme.accent, in: Circle())
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player.playPause")

            Button {
                Task { await model.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .frame(width: 48, height: 48)
            }
            .disabled(!model.canGoNext)
            .accessibilityLabel("Next track")
            .accessibilityIdentifier("player.next")

            Button {
                Task { await model.cycleRepeatMode() }
            } label: {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(model.repeatMode == .off ? Color.white.opacity(0.65) : Theme.accent)
            }
            .accessibilityLabel(repeatLabel)
            .accessibilityIdentifier("player.repeat")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var repeatLabel: String {
        switch model.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    private var titleText: String {
        guard let track = model.currentTrack else { return "Nothing playing" }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled audio" : title
    }

    private var artistText: String {
        guard let track = model.currentTrack else { return "" }
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? "Unknown artist" : artist
    }
}
