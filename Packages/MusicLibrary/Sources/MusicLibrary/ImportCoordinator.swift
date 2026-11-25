import Foundation
import MusicCore

public actor ImportCoordinator {
    private let gateway: any TelegramGateway
    private let store: any LibraryStore
    private let fileStore: LibraryFileStore
    private let now: @Sendable () -> Date
    private var tasks: [ImportJob.ID: Task<Void, Never>] = [:]
    private var taskTokens: [ImportJob.ID: UUID] = [:]
    private var pendingJobIDs: [ImportJob.ID] = []
    private var activeJobID: ImportJob.ID?
    private var isRecovering = false
    private var progressTasks: [ImportJob.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var mutationTail: (token: UUID, task: Task<Void, Never>)?

    public init(
        gateway: any TelegramGateway,
        store: any LibraryStore,
        fileStore: LibraryFileStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.gateway = gateway
        self.store = store
        self.fileStore = fileStore
        self.now = now
    }

    public func enqueue(
        _ audios: [TelegramAudio],
        from sourceChat: TelegramChat
    ) async throws -> ImportJob {
        let job = try ImportJob(
            sourceChat: sourceChat,
            items: audios.map { try ImportItem(audio: $0) }
        )
        try await saveNewJob(job)
        start(job.id)
        return job
    }

    public func pause(jobID: ImportJob.ID) async throws -> ImportJob {
        let pausing = try await changeJob(jobID) { job in
            guard job.status == .active else {
                throw DomainError.invalidStateTransition(
                    from: String(describing: job.status),
                    to: String(describing: ImportJobStatus.pausing)
                )
            }
            return try job.transition(to: .pausing, updatedAt: self.timestamp(after: job.updatedAt))
        }
        pendingJobIDs.removeAll { $0 == jobID }
        let task = tasks[jobID]
        task?.cancel()
        if let item = pausing.items.first(where: { $0.status == .importing }) {
            await gateway.cancelDownload(for: item.id)
        }
        await task?.value
        await waitForProgressTasks(jobID)
        return try await finishPause(jobID)
    }

    public func resume(jobID: ImportJob.ID) async throws -> ImportJob {
        let task = tasks[jobID]
        await task?.value
        let resumable = try await changeJob(jobID) { job in
            let resumable: ImportJob
            switch job.status {
            case .paused:
                resumable = try job.transition(to: .active, updatedAt: self.timestamp(after: job.updatedAt))
            case .waitingToResume:
                let queued = try job.transition(to: .queued, updatedAt: self.timestamp(after: job.updatedAt))
                resumable = try queued.transition(to: .active, updatedAt: self.timestamp(after: queued.updatedAt))
            default:
                throw DomainError.invalidStateTransition(
                    from: String(describing: job.status),
                    to: String(describing: ImportJobStatus.active)
                )
            }
            return resumable
        }
        start(jobID)
        return resumable
    }

    public func cancel(jobID: ImportJob.ID) async throws -> ImportJob {
        let previous = try await store.importJob(id: jobID)
        let cancelled = try await changeJob(jobID) { job in
            guard [ImportJobStatus.queued, .active, .pausing, .paused, .waitingToResume].contains(job.status) else {
                throw DomainError.invalidStateTransition(
                    from: String(describing: job.status),
                    to: String(describing: ImportJobStatus.cancelled)
                )
            }
            let normalized: ImportJob
            if job.status == .waitingToResume {
                let queued = try job.transition(to: .queued, updatedAt: self.timestamp(after: job.updatedAt))
                normalized = queued
            } else {
                normalized = job
            }
            let items = try normalized.items.map { item in
                if item.status == .waiting || item.status == .importing {
                    return try item.transition(to: .cancelled, progress: item.progress)
                }
                return item
            }
            return try ImportJob(
                id: normalized.id,
                sourceChat: normalized.sourceChat,
                items: items,
                status: .cancelled,
                createdAt: normalized.createdAt,
                updatedAt: self.timestamp(after: normalized.updatedAt)
            )
        }
        pendingJobIDs.removeAll { $0 == jobID }
        let task = tasks[jobID]
        task?.cancel()
        if let item = previous.items.first(where: { $0.status == .importing }) {
            await gateway.cancelDownload(for: item.id)
        }
        await task?.value
        await waitForProgressTasks(jobID)
        return try await store.importJob(id: jobID)
    }

    public func retry(jobID: ImportJob.ID) async throws -> ImportJob {
        let task = tasks[jobID]
        await task?.value
        let queued = try await changeJob(jobID) { job in
            try job.transition(to: .queued, updatedAt: self.timestamp(after: job.updatedAt))
        }
        start(jobID)
        return queued
    }

    public func recover() async throws {
        isRecovering = true
        defer {
            isRecovering = false
            startNextJob()
        }
        let runningTasks = tasks.values
        for task in runningTasks { task.cancel() }
        for task in runningTasks { await task.value }

        let jobs = try await store.importJobs()
        let tracks = try await store.tracks()
        try await fileStore.cleanupOrphanedFiles(referencedBy: Set(tracks.map(\.localURL)))
        pendingJobIDs.removeAll()
        for job in jobs.reversed() {
            switch job.status {
            case .active, .waitingToResume:
                _ = try await changeJob(job.id) { current in
                    guard current.status == .active || current.status == .waitingToResume else { return current }
                    let normalized = try self.resetImportingItems(current)
                    if normalized.status == .waitingToResume {
                        return try normalized.transition(
                            to: .queued,
                            updatedAt: self.timestamp(after: normalized.updatedAt)
                        )
                    }
                    let waiting = try normalized.transition(
                        to: .waitingToResume,
                        updatedAt: self.timestamp(after: normalized.updatedAt)
                    )
                    return try waiting.transition(
                        to: .queued,
                        updatedAt: self.timestamp(after: waiting.updatedAt)
                    )
                }
                start(job.id)
            case .pausing:
                _ = try await finishPause(job.id)
            case .queued:
                start(job.id)
            default:
                continue
            }
        }
    }

    public func wait(for jobID: ImportJob.ID) async throws -> ImportJob {
        for await jobs in store.observeImportJobs() {
            if let job = jobs.first(where: { $0.id == jobID }), isTerminal(job.status) {
                return job
            }
        }
        throw DomainError.library(.unavailable)
    }

    public func deleteTrack(id: Track.ID) async throws {
        let track = try await store.track(id: id)
        try await store.deleteTrack(id: id)
        try await fileStore.deleteFile(at: track.localURL)
    }

    private func start(_ jobID: ImportJob.ID) {
        guard tasks[jobID] == nil,
              activeJobID != jobID,
              !pendingJobIDs.contains(jobID) else { return }
        pendingJobIDs.append(jobID)
        startNextJob()
    }

    private func startNextJob() {
        guard !isRecovering, activeJobID == nil, let jobID = pendingJobIDs.first else { return }
        pendingJobIDs.removeFirst()
        let token = UUID()
        activeJobID = jobID
        taskTokens[jobID] = token
        tasks[jobID] = Task { await self.run(jobID, token: token) }
    }

    private func finishJob(_ jobID: ImportJob.ID, token: UUID) {
        guard taskTokens[jobID] == token else { return }
        tasks[jobID] = nil
        taskTokens[jobID] = nil
        if activeJobID == jobID { activeJobID = nil }
        startNextJob()
    }

    private func finishPause(_ jobID: ImportJob.ID) async throws -> ImportJob {
        _ = try await changeJob(jobID) { job in
            guard job.status == .pausing else { return job }
            let normalized = try self.resetImportingItems(job)
            return try normalized.transition(to: .paused, updatedAt: self.timestamp(after: normalized.updatedAt))
        }
        return try await store.importJob(id: jobID)
    }

    private func saveNewJob(_ job: ImportJob) async throws {
        let store = self.store
        _ = try await mutate {
            try await store.saveImportJob(job)
        }
    }

    private func changeJob(
        _ jobID: ImportJob.ID,
        _ change: @escaping @Sendable (ImportJob) throws -> ImportJob
    ) async throws -> ImportJob {
        let store = self.store
        return try await mutate {
            let job = try await store.importJob(id: jobID)
            let updated = try change(job)
            try await store.saveImportJob(updated)
            return updated
        }
    }

    private func mutate<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        // Read and save in one queue so concurrent callbacks cannot persist snapshots out of order.
        let previous = mutationTail?.task
        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let task: Task<Void, Never> = Task { [weak self] in
                await previous?.value
                do {
                    let result = try await operation()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
                if let self { await self.finishMutation(token) }
            }
            mutationTail = (token, task)
        }
    }

    private func finishMutation(_ token: UUID) {
        if mutationTail?.token == token { mutationTail = nil }
    }

    private func run(_ jobID: ImportJob.ID, token: UUID) async {
        defer {
            finishJob(jobID, token: token)
        }
        do {
            var job = try await store.importJob(id: jobID)
            if job.status == .queued || job.status == .paused {
                guard await gateway.authState == .authenticated else {
                    _ = try await changeJob(jobID) { current in
                        guard current.status == .queued || current.status == .paused else { return current }
                        return try current.transition(
                            to: .waitingToResume,
                            updatedAt: self.timestamp(after: current.updatedAt)
                        )
                    }
                    return
                }
                job = try await changeJob(jobID) { current in
                    guard current.status == .queued || current.status == .paused else { return current }
                    return try current.transition(to: .active, updatedAt: self.timestamp(after: current.updatedAt))
                }
            }
            guard job.status == .active else { return }

            for index in job.items.indices {
                try Task.checkCancellation()
                let latest = try await store.importJob(id: jobID)
                guard latest.status == .active else { return }
                let item = latest.items[index]
                if item.status == .imported || item.status == .duplicate { continue }
                if item.status == .failed || item.status == .cancelled { continue }
                do {
                    try await importItem(latest, index: index)
                } catch is CancellationError {
                    try? await settleCancellation(jobID)
                    return
                } catch {
                    try await failOrWait(latest, index: index, error: domainError(error))
                }
            }

            _ = try await changeJob(jobID) { finished in
                guard finished.status == .active else { return finished }
                let allImported = finished.items.allSatisfy { $0.status == .imported || $0.status == .duplicate }
                let status: ImportJobStatus = allImported ? .completed : .partialFailure
                return try finished.transition(to: status, updatedAt: self.timestamp(after: finished.updatedAt))
            }
        } catch {
            try? await settleCancellation(jobID)
        }
    }

    private func importItem(_ job: ImportJob, index: Int) async throws {
        var current = try await store.importJob(id: job.id)
        guard current.status == .active else { return }
        current = try await changeJob(job.id) { latest in
            guard latest.status == .active else { return latest }
            let currentItem = latest.items[index]
            guard currentItem.status == .importing else { return latest }
            let waiting = try currentItem.transition(to: .waiting, progress: currentItem.progress)
            return try self.replacing(waiting, in: latest)
        }
        var item = current.items[index]
        guard current.status == .active, item.status == .waiting else { return }

        if let existing = try await store.track(for: item.id) {
            try await markDuplicate(item, trackID: existing.id, in: current)
            return
        }
        try await fileStore.checkCapacity(bytes: item.audio.fileSize)

        current = try await changeJob(job.id) { latest in
            guard latest.status == .active else { return latest }
            let currentItem = latest.items[index]
            guard currentItem.status == .waiting else { return latest }
            let importing = try currentItem.transition(to: .importing)
            return try self.replacing(importing, in: latest)
        }
        item = current.items[index]
        guard current.status == .active, item.status == .importing else { return }
        try Task.checkCancellation()

        let gateway = self.gateway
        let downloadedURL = try await withTaskCancellationHandler {
            try await gateway.downloadAudio(item.audio) { progress in
                Task { [weak self] in await self?.recordProgress(job.id, identity: item.id, progress: progress) }
            }
        } onCancel: {
            Task { await gateway.cancelDownload(for: item.id) }
        }

        let localURL = try await fileStore.importDownloadedFile(
            for: item.audio,
            at: downloadedURL,
            removingSourceOnSuccess: true
        )
        var insertedTrackID: Track.ID?
        do {
            try Task.checkCancellation()
            if let existing = try await store.track(for: item.id) {
                try await fileStore.deleteFile(at: localURL)
                try await markDuplicate(item, trackID: existing.id, in: current)
                return
            }
            let track = try Track(
                telegramIdentity: item.audio.identity,
                sourceChat: current.sourceChat,
                title: item.audio.title,
                artist: item.audio.performer,
                duration: item.audio.duration,
                fileSize: item.audio.fileSize,
                importedAt: now(),
                localURL: localURL
            )
            do {
                try await store.insertTrack(track)
            } catch let error as DomainError {
                if case .duplicateTrack = error,
                   let existing = try? await store.track(for: item.id) {
                    try await fileStore.deleteFile(at: localURL)
                    try await markDuplicate(item, trackID: existing.id, in: current)
                    return
                }
                throw error
            }
            insertedTrackID = track.id
            _ = try await changeJob(job.id) { latest in
                guard latest.status == .active, latest.items[index].status == .importing else {
                    throw CancellationError()
                }
                let currentItem = latest.items[index]
                let imported = try currentItem.transition(
                    to: .imported,
                    progress: currentItem.progress,
                    trackID: track.id
                )
                return try self.replacing(imported, in: latest)
            }
        } catch {
            if let insertedTrackID {
                do {
                    try await store.deleteTrack(id: insertedTrackID)
                } catch {
                    // Recovery can account for the promoted file if metadata rollback fails.
                    throw error
                }
            }
            try? await fileStore.deleteFile(at: localURL)
            throw error
        }
    }

    private func recordProgress(
        _ jobID: ImportJob.ID,
        identity: TelegramAudioIdentity,
        progress: DownloadProgress
    ) async {
        let previous = progressTasks[jobID]?.task
        let token = UUID()
        let task: Task<Void, Never> = Task { [weak self] in
            await previous?.value
            if let self {
                await self.persistProgress(jobID, identity: identity, progress: progress)
                await self.finishProgress(jobID, token: token)
            }
        }
        progressTasks[jobID] = (token, task)
    }

    private func persistProgress(
        _ jobID: ImportJob.ID,
        identity: TelegramAudioIdentity,
        progress: DownloadProgress
    ) async {
        _ = try? await changeJob(jobID) { job in
            guard let index = job.items.firstIndex(where: { $0.id == identity }) else { return job }
            let item = job.items[index]
            guard item.status == .importing,
                  progress.completedBytes >= (item.progress?.completedBytes ?? 0) else { return job }
            let updatedItem = try ImportItem(audio: item.audio, status: .importing, progress: progress)
            return try self.replacing(updatedItem, in: job)
        }
    }

    private func finishProgress(_ jobID: ImportJob.ID, token: UUID) {
        if progressTasks[jobID]?.token == token { progressTasks[jobID] = nil }
    }

    private func waitForProgressTasks(_ jobID: ImportJob.ID) async {
        while let pending = progressTasks[jobID] {
            await pending.task.value
            if progressTasks[jobID]?.token == pending.token { progressTasks[jobID] = nil }
        }
    }

    private func markDuplicate(
        _ item: ImportItem,
        trackID: Track.ID,
        in job: ImportJob
    ) async throws {
        _ = try await changeJob(job.id) { latest in
            guard latest.status == .active,
                  let index = latest.items.firstIndex(where: { $0.id == item.id }),
                  latest.items[index].status == .waiting || latest.items[index].status == .importing else {
                return latest
            }
            let duplicate = try latest.items[index].transition(to: .duplicate, trackID: trackID)
            return try self.replacing(duplicate, in: latest)
        }
    }

    private func failOrWait(
        _ job: ImportJob,
        index: Int,
        error: DomainError
    ) async throws {
        _ = try await changeJob(job.id) { latest in
            guard latest.status == .active, latest.items.indices.contains(index) else { return latest }
            let item = latest.items[index]
            guard item.status == .waiting || item.status == .importing else { return latest }
            if self.isConnectivityError(error) {
                let normalized = try self.resetImportingItems(latest)
                return try normalized.transition(
                    to: .waitingToResume,
                    updatedAt: self.timestamp(after: normalized.updatedAt)
                )
            }
            let failed = try item.transition(to: .failed, progress: item.progress, error: error)
            return try self.replacing(failed, in: latest)
        }
    }

    private func settleCancellation(_ jobID: ImportJob.ID) async throws {
        _ = try await changeJob(jobID) { job in
            guard job.status == .pausing || job.status == .active else { return job }
            let normalized = try self.resetImportingItems(job)
            let status: ImportJobStatus = job.status == .pausing ? .paused : .waitingToResume
            return try normalized.transition(to: status, updatedAt: self.timestamp(after: normalized.updatedAt))
        }
    }

    nonisolated private func replacing(_ item: ImportItem, in job: ImportJob) throws -> ImportJob {
        guard let index = job.items.firstIndex(where: { $0.id == item.id }) else {
            throw DomainError.invalidImportJob
        }
        var items = job.items
        items[index] = item
        return try ImportJob(
            id: job.id,
            sourceChat: job.sourceChat,
            items: items,
            status: job.status,
            createdAt: job.createdAt,
            updatedAt: timestamp(after: job.updatedAt)
        )
    }

    nonisolated private func resetImportingItems(_ job: ImportJob) throws -> ImportJob {
        let items = try job.items.map { item in
            item.status == .importing ? try item.transition(to: .waiting, progress: item.progress) : item
        }
        return try ImportJob(
            id: job.id,
            sourceChat: job.sourceChat,
            items: items,
            status: job.status,
            createdAt: job.createdAt,
            updatedAt: timestamp(after: job.updatedAt)
        )
    }

    nonisolated private func timestamp(after previous: Date) -> Date {
        let current = now()
        guard current > previous else {
            // Distinct timestamps let the durable store reject snapshots written out of order.
            return previous.addingTimeInterval(0.001)
        }
        return current
    }

    private func domainError(_ error: Error) -> DomainError {
        if let error = error as? DomainError { return error }
        if let error = error as? TelegramGatewayError { return .telegram(error) }
        if let error = error as? LibraryStoreError { return .library(error) }
        return .telegram(.downloadFailed)
    }

    nonisolated private func isConnectivityError(_ error: DomainError) -> Bool {
        switch error {
        case .unauthenticated, .telegram(.notAuthorized), .telegram(.networkUnavailable),
             .telegram(.rateLimited), .telegram(.serviceUnavailable):
            return true
        default:
            return false
        }
    }

    private func isTerminal(_ status: ImportJobStatus) -> Bool {
        status == .completed || status == .partialFailure || status == .cancelled
    }
}
