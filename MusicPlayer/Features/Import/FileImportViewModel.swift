import Foundation
import MusicCore
import MusicLibrary
import Observation

/// Drives the Files-app import sheet. Telegram imports keep their own durable queue.
@MainActor
@Observable
final class FileImportViewModel {
    private let importer: LocalFileImporter
    private var task: Task<Void, Never>?

    var isImporting = false
    var progress: LocalFileImportProgress?
    var summary: LocalFileImportSummary?
    var isShowingPicker = false
    var errorMessage: String?

    init(importer: LocalFileImporter) {
        self.importer = importer
    }

    var isPresentingStatus: Bool { isImporting || summary != nil }

    /// Starts a batch; files arrive from the picker or from another app opening them.
    func importFiles(_ urls: [URL]) {
        guard task == nil, !urls.isEmpty else { return }
        isImporting = true
        summary = nil
        errorMessage = nil
        progress = LocalFileImportProgress(
            completed: 0,
            total: urls.count,
            currentFileName: urls.first?.lastPathComponent
        )

        let importer = self.importer
        task = Task { [weak self] in
            let result = await importer.importFiles(urls) { update in
                Task { @MainActor in
                    self?.progress = update
                }
            }
            guard let self else { return }
            self.finish(result)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        guard !isImporting else { return }
        summary = nil
        errorMessage = nil
        progress = nil
    }

    func reportPickerFailure(_ error: Error) {
        errorMessage = userMessage(for: error)
    }

    private func finish(_ result: LocalFileImportSummary) {
        summary = result
        progress = nil
        isImporting = false
        task = nil
    }
}
