import Foundation
import MusicCore
import SwiftData

public actor SwiftDataLibraryStore: LibraryStore {
    private let container: ModelContainer
    private var trackObservers: [UUID: AsyncStream<[Track]>.Continuation] = [:]
    private var jobObservers: [UUID: AsyncStream<[ImportJob]>.Continuation] = [:]
    private var favoriteObservers: [UUID: AsyncStream<Set<Track.ID>>.Continuation] = [:]
    private var playlistObservers: [UUID: AsyncStream<[Playlist]>.Continuation] = [:]

    public init(container: ModelContainer) {
        self.container = container
    }

    public convenience init() throws {
        try self.init(container: Self.makeContainer())
    }

    public static func makeContainer(
        inMemory: Bool = false,
        storageURL: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema([
            PersistedTrack.self,
            PersistedImportJob.self,
            PersistedFavorite.self,
            PersistedPlaylist.self
        ])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let url = try storageURL ?? defaultStorageURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            configuration = ModelConfiguration(schema: schema, url: url)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public static func defaultStorageURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DomainError.library(.unavailable)
        }
        return support.appendingPathComponent("MusicLibrary", isDirectory: true)
            .appendingPathComponent("Library.store", isDirectory: false)
    }

    public func tracks() async throws -> [Track] {
        try loadTracks()
    }

    var trackObserverCount: Int { trackObservers.count }

    nonisolated public func observeTracks() -> AsyncStream<[Track]> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTrackObserver(id) }
            }
            Task { await self.addTrackObserver(id, continuation: continuation) }
        }
    }

    public func track(id: Track.ID) async throws -> Track {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedTrack>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw DomainError.trackNotFound(id)
        }
        return try record.value()
    }

    public func track(for identity: TelegramAudioIdentity) async throws -> Track? {
        let key = identityKey(identity)
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedTrack>(predicate: #Predicate { $0.identityKey == key })
        return try context.fetch(descriptor).first?.value()
    }

    public func insertTrack(_ track: Track) async throws {
        if try await self.track(for: track.telegramIdentity) != nil {
            throw DomainError.duplicateTrack(track.telegramIdentity)
        }
        let context = ModelContext(container)
        context.insert(PersistedTrack(track: track))
        do {
            try context.save()
        } catch {
            context.rollback()
            if try await self.track(for: track.telegramIdentity) != nil {
                throw DomainError.duplicateTrack(track.telegramIdentity)
            }
            throw DomainError.library(.writeFailed)
        }
        await publishTracks()
    }

    public func deleteTrack(id: Track.ID) async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedTrack>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw DomainError.trackNotFound(id)
        }
        context.delete(record)
        let favorites = try context.fetch(
            FetchDescriptor<PersistedFavorite>(predicate: #Predicate { $0.trackID == id })
        )
        favorites.forEach(context.delete)
        let playlists = try context.fetch(FetchDescriptor<PersistedPlaylist>())
        for playlist in playlists where playlist.trackIDs.contains(id) {
            playlist.trackIDs.removeAll { $0 == id }
            playlist.updatedAt = Date()
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw DomainError.library(.writeFailed)
        }
        await publishTracks()
        await publishFavorites()
        await publishPlaylists()
    }

    public func importJobs() async throws -> [ImportJob] {
        try loadJobs()
    }

    var jobObserverCount: Int { jobObservers.count }

    nonisolated public func observeImportJobs() -> AsyncStream<[ImportJob]> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeJobObserver(id) }
            }
            Task { await self.addJobObserver(id, continuation: continuation) }
        }
    }

    public func importJob(id: ImportJob.ID) async throws -> ImportJob {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedImportJob>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw DomainError.importJobNotFound(id)
        }
        return try record.value()
    }

    public func saveImportJob(_ job: ImportJob) async throws {
        let context = ModelContext(container)
        let jobID = job.id
        let descriptor = FetchDescriptor<PersistedImportJob>(predicate: #Predicate { $0.id == jobID })
        do {
            if let record = try context.fetch(descriptor).first {
                let persisted = try record.value()
                try record.update(with: try persisted.merging(job))
            } else {
                context.insert(try PersistedImportJob(job: job))
            }
            try context.save()
        } catch let error as DomainError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw DomainError.library(.writeFailed)
        }
        await publishJobs()
    }

    func addTrackObserver(
        _ id: UUID,
        continuation: AsyncStream<[Track]>.Continuation
    ) async {
        guard let snapshot = try? loadTracks() else {
            continuation.finish()
            return
        }
        trackObservers[id] = continuation
        if case .terminated = continuation.yield(snapshot) { trackObservers[id] = nil }
    }

    private func removeTrackObserver(_ id: UUID) {
        trackObservers[id] = nil
    }

    private func publishTracks() async {
        guard let snapshot = try? loadTracks() else {
            for continuation in trackObservers.values { continuation.finish() }
            trackObservers.removeAll()
            return
        }
        for continuation in trackObservers.values { continuation.yield(snapshot) }
    }

    func addJobObserver(
        _ id: UUID,
        continuation: AsyncStream<[ImportJob]>.Continuation
    ) async {
        guard let snapshot = try? loadJobs() else {
            continuation.finish()
            return
        }
        jobObservers[id] = continuation
        if case .terminated = continuation.yield(snapshot) { jobObservers[id] = nil }
    }

    private func removeJobObserver(_ id: UUID) {
        jobObservers[id] = nil
    }

    private func publishJobs() async {
        guard let snapshot = try? loadJobs() else {
            for continuation in jobObservers.values { continuation.finish() }
            jobObservers.removeAll()
            return
        }
        for continuation in jobObservers.values { continuation.yield(snapshot) }
    }

    private func loadTracks() throws -> [Track] {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PersistedTrack>())
        return try records.map { try $0.value() }.sortedNewestFirst { $0.importedAt }
    }

    private func loadJobs() throws -> [ImportJob] {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PersistedImportJob>())
        return try records.map { try $0.value() }.sortedNewestFirst { $0.createdAt }
    }

    private func identityKey(_ identity: TelegramAudioIdentity) -> String {
        "\(identity.chatID):\(identity.messageID)"
    }
}

private extension ImportJob {
    func merging(_ incoming: ImportJob) throws -> ImportJob {
        guard incoming.id == id, incoming.createdAt == createdAt else {
            throw DomainError.library(.corruptData)
        }
        guard incoming.updatedAt >= updatedAt else { return self }
        let advances = incoming.updatedAt > updatedAt
        guard incoming.status == status || (advances && canAdvanceStatus(to: incoming.status)) else {
            return self
        }

        let currentItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let mergedItems = try incoming.items.map { proposed -> ImportItem in
            guard let current = currentItems[proposed.id] else { return proposed }
            let progress = Self.monotonicProgress(proposed.progress, current.progress)
            if proposed.status == current.status {
                switch current.status {
                case .imported, .duplicate:
                    return try ImportItem(
                        audio: proposed.audio,
                        status: current.status,
                        progress: progress,
                        trackID: current.trackID
                    )
                case .failed:
                    guard advances else { return current }
                    return try ImportItem(
                        audio: proposed.audio,
                        status: .failed,
                        progress: progress,
                        error: proposed.error
                    )
                default:
                    return try ImportItem(
                        audio: proposed.audio,
                        status: current.status,
                        progress: progress
                    )
                }
            }
            guard advances, current.canTransition(to: proposed.status) else { return current }
            return try ImportItem(
                audio: proposed.audio,
                status: proposed.status,
                progress: progress,
                trackID: proposed.trackID,
                error: proposed.error
            )
        }
        guard incoming.status != status || mergedItems != items else { return self }
        let merged = try ImportJob(
            id: id,
            sourceChat: incoming.sourceChat,
            items: mergedItems,
            status: incoming.status,
            createdAt: createdAt,
            updatedAt: incoming.updatedAt
        )
        return merged == self ? self : merged
    }

    private func canAdvanceStatus(to target: ImportJobStatus) -> Bool {
        if canTransition(to: target) { return true }
        // Recovery and resume may normalize through queued before saving one snapshot.
        switch (status, target) {
        case (.active, .queued), (.waitingToResume, .active), (.waitingToResume, .cancelled):
            return true
        default:
            return false
        }
    }

    private static func monotonicProgress(
        _ proposed: DownloadProgress?,
        _ current: DownloadProgress?
    ) -> DownloadProgress? {
        guard let proposed else { return current }
        guard let current else { return proposed }
        return proposed.completedBytes >= current.completedBytes ? proposed : current
    }
}

private extension Array where Element: Identifiable {
    func sortedNewestFirst<T: Comparable>(by date: (Element) -> T) -> [Element] {
        sorted {
            if date($0) == date($1) { return String(describing: $0.id) > String(describing: $1.id) }
            return date($0) > date($1)
        }
    }
    // MARK: - Favorites

    public func favoriteTrackIDs() async throws -> Set<Track.ID> {
        try loadFavorites()
    }

    nonisolated public func observeFavoriteTrackIDs() -> AsyncStream<Set<Track.ID>> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFavoriteObserver(id) }
            }
            Task { await self.addFavoriteObserver(id, continuation: continuation) }
        }
    }

    public func setFavorite(_ isFavorite: Bool, forTrack id: Track.ID) async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedFavorite>(predicate: #Predicate { $0.trackID == id })
        let existing = try context.fetch(descriptor)
        if isFavorite {
            if existing.isEmpty {
                let trackDescriptor = FetchDescriptor<PersistedTrack>(predicate: #Predicate { $0.id == id })
                guard try context.fetch(trackDescriptor).first != nil else {
                    throw DomainError.trackNotFound(id)
                }
                context.insert(PersistedFavorite(trackID: id))
            }
        } else {
            existing.forEach(context.delete)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw DomainError.library(.writeFailed)
        }
        await publishFavorites()
    }

    func addFavoriteObserver(
        _ id: UUID,
        continuation: AsyncStream<Set<Track.ID>>.Continuation
    ) async {
        guard let snapshot = try? loadFavorites() else {
            continuation.finish()
            return
        }
        favoriteObservers[id] = continuation
        if case .terminated = continuation.yield(snapshot) { favoriteObservers[id] = nil }
    }

    private func removeFavoriteObserver(_ id: UUID) {
        favoriteObservers[id] = nil
    }

    private func publishFavorites() async {
        guard let snapshot = try? loadFavorites() else {
            for continuation in favoriteObservers.values { continuation.finish() }
            favoriteObservers.removeAll()
            return
        }
        for continuation in favoriteObservers.values { continuation.yield(snapshot) }
    }

    private func loadFavorites() throws -> Set<Track.ID> {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PersistedFavorite>(sortBy: [SortDescriptor(\.createdAt)]))
        return Set(records.map(\.trackID))
    }

    // MARK: - Playlists

    public func playlists() async throws -> [Playlist] {
        try loadPlaylists()
    }

    nonisolated public func observePlaylists() -> AsyncStream<[Playlist]> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removePlaylistObserver(id) }
            }
            Task { await self.addPlaylistObserver(id, continuation: continuation) }
        }
    }

    public func createPlaylist(name: String) async throws -> Playlist {
        let playlist = try Playlist(name: name)
        let context = ModelContext(container)
        context.insert(PersistedPlaylist(playlist: playlist))
        do {
            try context.save()
        } catch {
            context.rollback()
            throw DomainError.library(.writeFailed)
        }
        await publishPlaylists()
        return playlist
    }

    public func deletePlaylist(id: Playlist.ID) async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedPlaylist>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw DomainError.playlistNotFound(id)
        }
        context.delete(record)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw DomainError.library(.writeFailed)
        }
        await publishPlaylists()
    }

    public func renamePlaylist(id: Playlist.ID, to name: String) async throws {
        try await mutatePlaylist(id: id) { playlist in
            try playlist.renamed(name)
        }
    }

    public func addTracks(_ trackIDs: [Track.ID], toPlaylist id: Playlist.ID) async throws {
        try await mutatePlaylist(id: id) { playlist in
            try playlist.adding(trackIDs)
        }
    }

    public func removeTrack(_ trackID: Track.ID, fromPlaylist id: Playlist.ID) async throws {
        try await mutatePlaylist(id: id) { playlist in
            try playlist.removing(trackID)
        }
    }

    private func mutatePlaylist(
        id: Playlist.ID,
        change: (Playlist) throws -> Playlist
    ) async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PersistedPlaylist>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else {
            throw DomainError.playlistNotFound(id)
        }
        let updated = try change(try record.value())
        record.update(with: updated)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw DomainError.library(.writeFailed)
        }
        await publishPlaylists()
    }

    func addPlaylistObserver(
        _ id: UUID,
        continuation: AsyncStream<[Playlist]>.Continuation
    ) async {
        guard let snapshot = try? loadPlaylists() else {
            continuation.finish()
            return
        }
        playlistObservers[id] = continuation
        if case .terminated = continuation.yield(snapshot) { playlistObservers[id] = nil }
    }

    private func removePlaylistObserver(_ id: UUID) {
        playlistObservers[id] = nil
    }

    private func publishPlaylists() async {
        guard let snapshot = try? loadPlaylists() else {
            for continuation in playlistObservers.values { continuation.finish() }
            playlistObservers.removeAll()
            return
        }
        for continuation in playlistObservers.values { continuation.yield(snapshot) }
    }

    private func loadPlaylists() throws -> [Playlist] {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<PersistedPlaylist>(sortBy: [SortDescriptor(\.createdAt)])
        )
        return try records.map { try $0.value() }
    }

}
