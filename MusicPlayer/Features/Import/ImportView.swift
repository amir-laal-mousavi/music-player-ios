import MusicLibrary
import SwiftUI
import UniformTypeIdentifiers

/// The Import tab: pick audio files and watch the batch progress in place.
struct ImportView: View {
    @Bindable var model: FileImportViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                chooseButton
                if model.isImporting {
                    progressCard
                } else if let summary = model.summary {
                    summaryCard(summary)
                }
                if let errorMessage = model.errorMessage {
                    StatusBanner(kind: .error, message: errorMessage)
                }
                footer
            }
            .padding(20)
        }
        .navigationTitle("Import")
        .fileImporter(
            isPresented: $model.isShowingPicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importFiles(urls)
            case .failure(let error):
                model.reportPickerFailure(error)
            }
        }
        .accessibilityIdentifier("import.page")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Bring your own music")
                .font(.title2.bold())
            Text("Pick audio files from the Files app or any app that can share them with MusicPlayer. Every song is copied into your library and plays offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var chooseButton: some View {
        Button {
            model.isShowingPicker = true
        } label: {
            Label(model.isImporting ? "Importing…" : "Choose files", systemImage: "folder")
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .disabled(model.isImporting)
        .accessibilityIdentifier("import.choose")
    }

    @ViewBuilder
    private var progressCard: some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("import.progress")
                Text("\(progress.completed) of \(progress.total) files")
                    .font(.headline)
                if let name = progress.currentFileName {
                    Text(name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Cancel") { model.cancel() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("import.cancel")
            }
            .glassCard()
        } else {
            ProgressView()
                .glassCard()
        }
    }

    private func summaryCard(_ summary: LocalFileImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(headline(for: summary), systemImage: symbol(for: summary))
                .font(.headline)
                .accessibilityIdentifier("import.status")

            countRow(
                Format.count(summary.importedCount, singular: "song", plural: "songs"),
                detail: "added to your library"
            )
            if summary.duplicateCount > 0 {
                countRow(
                    Format.count(summary.duplicateCount, singular: "duplicate", plural: "duplicates"),
                    detail: "already in your library"
                )
            }
            if summary.failureCount > 0 {
                countRow(
                    Format.count(summary.failureCount, singular: "failure", plural: "failures"),
                    detail: "could not be imported"
                )
                ForEach(Array(summary.failedResults.prefix(4).enumerated()), id: \.offset) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.element.fileName)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let message = entry.element.errorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var footer: some View {
        Text("You can also send a single audio file from another app with “Open in MusicPlayer”.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func headline(for summary: LocalFileImportSummary) -> String {
        if summary.isCancelled { return "Import stopped" }
        if summary.failureCount > 0 { return "Finished with issues" }
        return "Import complete"
    }

    private func symbol(for summary: LocalFileImportSummary) -> String {
        if summary.isCancelled { return "stop.circle" }
        if summary.failureCount > 0 { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private func countRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.body.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
