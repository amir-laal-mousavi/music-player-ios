import MusicCore
import SwiftUI
import UIKit

struct NowPlayingView: View {
    @Bindable var model: NowPlayingViewModel
    @Bindable var equalizer: EqualizerStore
    let isFavorite: (Track) -> Bool
    let onToggleFavorite: (Track) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var artworkImage: UIImage?
    @State private var isShowingEqualizer = false

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingEqualizer = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Equalizer")
                    .accessibilityIdentifier("player.equalizer")
                }
                if let track = model.currentTrack {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onToggleFavorite(track)
                        } label: {
                            Image(systemName: isFavorite(track) ? "heart.fill" : "heart")
                        }
                        .tint(isFavorite(track) ? Theme.accent : .white)
                        .accessibilityIdentifier("player.favorite")
                    }
                }
            }
            .task { await model.start() }
            .sheet(isPresented: $isShowingEqualizer) {
                EqualizerView(store: equalizer) { settings in
                    Task { await model.applyEqualizer(settings) }
                }
            }
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

            HoldSeekButton(
                symbol: "backward.fill",
                direction: .backward,
                isEnabled: model.canGoPrevious,
                accessibilityLabel: "Previous track",
                accessibilityIdentifier: "player.previous",
                onTap: { await model.previous() },
                onSeek: { await model.skip(by: $0) }
            )

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

            HoldSeekButton(
                symbol: "forward.fill",
                direction: .forward,
                isEnabled: model.canGoNext,
                accessibilityLabel: "Next track",
                accessibilityIdentifier: "player.next",
                onTap: { await model.next() },
                onSeek: { await model.skip(by: $0) }
            )

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

/// Previous/next button that also rewinds or fast-forwards while held, like Music.
private struct HoldSeekButton: View {
    enum Direction {
        case backward
        case forward

        var step: TimeInterval { self == .backward ? -5 : 5 }
    }

    let symbol: String
    let direction: Direction
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let onTap: () async -> Void
    let onSeek: (TimeInterval) async -> Void

    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title2)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(
                "Touch and hold to \(direction == .forward ? "fast-forward" : "rewind")"
            )
            .accessibilityAction {
                guard isEnabled else { return }
                Task { await onTap() }
            }
    }

    private func beginPress() {
        guard isEnabled, holdTask == nil else { return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isHolding = true
            while !Task.isCancelled {
                await onSeek(direction.step)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func endPress() {
        let wasHolding = isHolding
        holdTask?.cancel()
        holdTask = nil
        isHolding = false
        guard isEnabled, !wasHolding else { return }
        Task { await onTap() }
    }
}
