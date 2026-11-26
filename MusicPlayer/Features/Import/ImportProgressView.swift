import MusicCore
import SwiftUI

struct ImportProgressView: View {
    @Bindable var model: ImportProgressViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                List {
                    ForEach(model.items) { item in
                        ImportItemRow(item: item)
                    }
                }
                .listStyle(.plain)
                controls
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("import.done")
                }
            }
            .task { await model.start() }
            .onDisappear { model.stop() }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.statusTitle)
                    .font(.headline)
                    .accessibilityIdentifier("import.status")
                Spacer()
                Text(Format.percent(model.summary.fraction))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: model.summary.fraction)
                .tint(Theme.accent)

            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = model.errorMessage {
                StatusBanner(kind: .error, message: errorMessage)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            if model.canPause {
                Button {
                    Task { await model.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("import.pause")
            }

            if model.canResume {
                Button {
                    Task { await model.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("import.resume")
            }

            if model.canRetry {
                Button {
                    Task { await model.retry() }
                } label: {
                    Label("Retry unfinished", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("import.retry")
            }

            if model.canCancel {
                Button(role: .destructive) {
                    Task { await model.cancel() }
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("import.cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(model.isWorking)
    }
}

struct ImportItemRow: View {
    let item: ImportItem

    private var title: String {
        let title = item.audio.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled audio" : title
    }

    private var statusLabel: String {
        switch item.status {
        case .waiting: return "Waiting"
        case .importing:
            let fraction = Format.progressFraction(item.progress)
            return fraction.map(Format.percent) ?? "Downloading"
        case .imported: return "Imported"
        case .duplicate: return "Already in library"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusTint: Color {
        switch item.status {
        case .imported: return .green
        case .duplicate: return Theme.accent
        case .failed: return .red
        case .cancelled: return .secondary
        case .waiting, .importing: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
            }

            if item.status == .importing, let fraction = Format.progressFraction(item.progress) {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
            }

            if let error = item.error {
                Text(error.userMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(statusLabel)")
    }
}
