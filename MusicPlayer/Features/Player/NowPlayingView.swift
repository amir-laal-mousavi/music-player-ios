import SwiftUI

struct NowPlayingView: View {
    @Bindable var model: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 8)
                artwork
                titleBlock
                progressBlock
                transport
                if let errorMessage = model.errorMessage {
                    StatusBanner(kind: .error, message: errorMessage)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
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
            .onDisappear { model.stop() }
        }
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Theme.artworkGradient(for: titleText))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 300)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .accessibilityHidden(true)
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let queueLabel = model.queueLabel {
                Text(queueLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
            .tint(Theme.accent)
            .disabled(!model.canSeek)
            .accessibilityLabel("Playback position")
            .accessibilityIdentifier("player.scrubber")

            HStack {
                Text(Format.duration(model.position))
                Spacer()
                Text(Format.duration(model.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button {
                Task { await model.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
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
                    .frame(width: 74, height: 74)
                    .background(Theme.accent, in: Circle())
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player.playPause")

            Button {
                Task { await model.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
            }
            .disabled(!model.canGoNext)
            .accessibilityLabel("Next track")
            .accessibilityIdentifier("player.next")
        }
        .buttonStyle(.plain)
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
