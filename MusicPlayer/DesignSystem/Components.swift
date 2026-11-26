import MusicCore
import SwiftUI

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 18)
            .foregroundStyle(.white)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: Theme.compactCornerRadius, style: .continuous)
            )
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 18)
            .foregroundStyle(.primary)
            .background(
                Theme.card.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: Theme.compactCornerRadius, style: .continuous)
            )
    }
}

struct StatusBanner: View {
    enum Kind {
        case error
        case warning
        case info
    }

    let kind: Kind
    let message: String

    private var tint: Color {
        switch kind {
        case .error: return .red
        case .warning: return .orange
        case .info: return Theme.accent
        }
    }

    private var systemImage: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("Offline. Imported music still plays.")
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.18))
        .accessibilityElement(children: .combine)
    }
}

struct ArtworkView: View {
    let title: String
    var artworkURL: URL?
    var size: CGFloat = 48

    var body: some View {
        ArtworkImage(url: artworkURL, title: title, size: size)
    }
}

struct TrackRowView: View {
    let track: Track

    private var titleText: String {
        track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled audio" : track.title
    }

    private var artistText: String {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? "Unknown artist" : artist
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(title: titleText, artworkURL: track.artworkURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(artistText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Format.duration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(titleText), \(artistText), \(Format.duration(track.duration))")
        .accessibilityAddTraits(.isButton)
    }
}

struct AudioRowView: View {
    let audio: TelegramAudio
    let isSelected: Bool
    let isImported: Bool

    private var titleText: String {
        audio.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled audio" : audio.title
    }

    private var performerText: String {
        let performer = audio.performer.trimmingCharacters(in: .whitespacesAndNewlines)
        return performer.isEmpty ? "Unknown artist" : performer
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(performerText)
                        .lineLimit(1)
                    if isImported {
                        Text("In library")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.16), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.duration(audio.duration))
                    .font(.caption.monospacedDigit())
                Text(Format.bytes(audio.fileSize))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(titleText), \(performerText), \(Format.duration(audio.duration))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Double tap to \(isSelected ? "deselect" : "select") this song")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    let systemImage: String
    let content: () -> Content

    init(title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(
                    Theme.card,
                    in: RoundedRectangle(cornerRadius: Theme.compactCornerRadius, style: .continuous)
                )
        }
    }
}

struct NowPlayingRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
    let startingIndex: Int
}

struct SectionHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
