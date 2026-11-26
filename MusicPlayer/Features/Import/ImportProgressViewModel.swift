import Foundation
import MusicCore
import MusicLibrary
import Observation

@MainActor
@Observable
final class ImportProgressViewModel {
    struct Summary: Equatable {
        let imported: Int
        let duplicates: Int
        let failed: Int
        let pending: Int
        let total: Int

        var finished: Int { imported + duplicates + failed }
        var fraction: Double {
            total == 0 ? 0 : Double(finished) / Double(total)
        }
        var isComplete: Bool { total > 0 && pending == 0 }
    }

    private let store: any LibraryStore
    private let coordinator: ImportCoordinator
    private let jobID: ImportJob.ID
    private var observation: Task<Void, Never>?

    var job: ImportJob?
    var errorMessage: String?
    var isWorking = false

    init(store: any LibraryStore, coordinator: ImportCoordinator, jobID: ImportJob.ID) {
        self.store = store
        self.coordinator = coordinator
        self.jobID = jobID
    }

    var items: [ImportItem] { job?.items ?? [] }

    var summary: Summary {
        let items = self.items
        return Summary(
            imported: items.filter { $0.status == .imported }.count,
            duplicates: items.filter { $0.status == .duplicate }.count,
            failed: items.filter { $0.status == .failed }.count,
            pending: items.filter { $0.status == .waiting || $0.status == .importing }.count,
            total: items.count
        )
    }

    var statusTitle: String {
        guard let status = job?.status else { return "Preparing import" }
        switch status {
        case .queued: return "Waiting to start"
        case .active: return "Importing"
        case .pausing: return "Pausing"
        case .paused: return "Paused"
        case .completed: return "Import complete"
        case .partialFailure: return "Finished with errors"
        case .cancelled: return "Import cancelled"
        case .waitingToResume: return "Waiting to resume"
        }
    }

    var detail: String {
        let summary = self.summary
        var parts = [Format.count(summary.finished, singular: "song ready", plural: "songs ready")]
        if summary.duplicates > 0 { parts.append("\(summary.duplicates) already in library") }
        if summary.failed > 0 { parts.append(Format.count(summary.failed, singular: "failed item", plural: "failed items")) }
        if summary.pending > 0 { parts.append("\(summary.pending) remaining") }
        return parts.joined(separator: " · ")
    }

    var canPause: Bool { job?.status == .active }
    var canResume: Bool { job?.status == .paused || job?.status == .waitingToResume }
    var canCancel: Bool {
        guard let status = job?.status else { return false }
        return [.queued, .active, .pausing, .paused, .waitingToResume].contains(status)
    }
    var canRetry: Bool { job?.status == .partialFailure || job?.status == .cancelled }

    func start() async {
        guard observation == nil else { return }
        let store = self.store
        let jobID = self.jobID
        observation = Task { [weak self] in
            for await jobs in store.observeImportJobs() {
                guard let self else { return }
                guard let match = jobs.first(where: { $0.id == jobID }) else { continue }
                self.job = match
            }
        }
        if let current = try? await store.importJob(id: jobID) {
            job = current
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    func pause() async {
        await perform { try await self.coordinator.pause(jobID: self.jobID) }
    }

    func resume() async {
        await perform { try await self.coordinator.resume(jobID: self.jobID) }
    }

    func cancel() async {
        await perform { try await self.coordinator.cancel(jobID: self.jobID) }
    }

    func retry() async {
        await perform { try await self.coordinator.retry(jobID: self.jobID) }
    }

    private func perform(_ operation: @escaping () async throws -> ImportJob) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            job = try await operation()
        } catch {
            errorMessage = userMessage(for: error)
        }
        isWorking = false
    }
}
