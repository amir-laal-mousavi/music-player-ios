import MusicLibrary
import SwiftUI

/// Progress and result surface for importing local audio files.
struct FileImportSheet: View {
    @Bindable var model: FileImportViewModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isImporting {
                    importingView
                } else {
                    summaryView
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .navigationTitle(model.isImporting ? "Importing" : "Import files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: model.isImporting ? .cancellationAction : .confirmationAction) {
                    if model.isImporting {
                        Button("Cancel") { model.cancel() }
                            .accessibilityIdentifier("fileImport.cancel")
                    } else {
                        Button("Done") { model.dismiss() }
                            .accessibilityIdentifier("fileImport.done")
                    }
                }
            }
            .interactiveDismissDisabled(model.isImporting)
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("fileImport.sheet")
    }

    private var importingView: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress = model.progress {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("fileImport.progress")

                Text("\(progress.completed) of \(progress.total) files")
                    .font(.headline)

                if let name = progress.currentFileName {
                    Text(name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                ProgressView()
            }

            Text("Each song is copied into your library, so it keeps playing offline even if you delete the original.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .glassCard()
    }

    @ViewBuilder
    private var summaryView: some View {
        if let summary = model.summary {
            VStack(alignment: .leading, spacing: 16) {
                Label(headline(for: summary), systemImage: symbol(for: summary))
                    .font(.headline)
                    .accessibilityIdentifier("fileImport.status")

                if summary.isCancelled && summary.results.isEmpty {
                    Text("No files were imported.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    countsView(summary)
                }

                if !summary.failedResults.isEmpty {
                    failuresView(summary)
                }

                Spacer(minLength: 0)
            }
        } else {
            Text("Choose audio files to add them to your library.")
                .foregroundStyle(.secondary)
        }
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

    private func countsView(_ summary: LocalFileImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            countRow(Format.count(summary.importedCount, singular: "song", plural: "songs"), detail: "added to your library")
            if summary.duplicateCount > 0 {
                countRow(Format.count(summary.duplicateCount, singular: "duplicate", plural: "duplicates"), detail: "already in your library")
            }
            if summary.failureCount > 0 {
                countRow(Format.count(summary.failureCount, singular: "failure", plural: "failures"), detail: "could not be imported")
            }
        }
        .glassCard()
    }

    private func countRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.body.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func failuresView(_ summary: LocalFileImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not imported")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(summary.failedResults.prefix(5).enumerated()), id: \.offset) { entry in
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
            if summary.failureCount > 5 {
                Text("and \(summary.failureCount - 5) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
