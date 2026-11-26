import Foundation
import MusicCore
import MusicLibrary
import Observation

@MainActor
@Observable
final class AudioBrowseViewModel {
    private let gateway: any TelegramGateway
    private let store: any LibraryStore
    private let coordinator: ImportCoordinator
    private let pageSize = 50

    let chat: TelegramChat

    var audios: [TelegramAudio] = []
    var selection: Set<TelegramAudioIdentity> = []
    var importedIdentities: Set<TelegramAudioIdentity> = []
    var cursor: TelegramAudio.MessageID?
    var hasMore = true
    var isLoading = false
    var isLoadingMore = false
    var isImporting = false
    var errorMessage: String?
    var importErrorMessage: String?

    init(
        chat: TelegramChat,
        gateway: any TelegramGateway,
        store: any LibraryStore,
        coordinator: ImportCoordinator
    ) {
        self.chat = chat
        self.gateway = gateway
        self.store = store
        self.coordinator = coordinator
    }

    var selectionCount: Int { selection.count }

    var selectedAudios: [TelegramAudio] {
        audios.filter { selection.contains($0.id) }
    }

    var isSelectionEmpty: Bool { selection.isEmpty }

    /// Selection is remembered by identity, so pages that arrive later stay consistent.
    func isSelected(_ audio: TelegramAudio) -> Bool {
        selection.contains(audio.id)
    }

    func isImported(_ audio: TelegramAudio) -> Bool {
        importedIdentities.contains(audio.id)
    }

    func toggle(_ audio: TelegramAudio) {
        if selection.contains(audio.id) {
            selection.remove(audio.id)
        } else {
            selection.insert(audio.id)
        }
    }

    func selectAllLoaded() {
        selection.formUnion(audios.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    func loadFirstPage() async {
        guard audios.isEmpty, !isLoading else { return }
        await loadPage()
    }

    func reload() async {
        cursor = nil
        hasMore = true
        audios = []
        importedIdentities = []
        clearSelection()
        await loadPage()
    }

    func loadMoreIfNeeded(current audio: TelegramAudio) async {
        guard audio.id == audios.last?.id, hasMore, !isLoading, !isLoadingMore else { return }
        await loadPage()
    }

    private func loadPage() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        if cursor == nil, !audios.isEmpty {
            hasMore = false
            return
        }

        let isFirstPage = audios.isEmpty
        if isFirstPage {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        errorMessage = nil
        defer {
            isLoading = false
            isLoadingMore = false
        }

        do {
            let request = try TelegramAudioPageRequest(
                chatID: chat.id,
                beforeMessageID: cursor,
                limit: pageSize
            )
            let page = try await gateway.loadAudioMessages(request)
            let existing = Set(audios.map(\.id))
            for message in page.messages where !existing.contains(message.id) {
                audios.append(message)
            }
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            await refreshImportedIdentities(page.messages)
        } catch {
            errorMessage = userMessage(for: error)
            hasMore = false
        }
    }

    private func refreshImportedIdentities(_ messages: [TelegramAudio]) async {
        for audio in messages {
            if (try? await store.track(for: audio.id)) != nil {
                importedIdentities.insert(audio.id)
            }
        }
    }

    func importSelection() async -> ImportJob? {
        guard !selection.isEmpty, !isImporting else { return nil }
        isImporting = true
        importErrorMessage = nil
        defer { isImporting = false }

        let audios = selectedAudios
        do {
            let job = try await coordinator.enqueue(audios, from: chat)
            clearSelection()
            return job
        } catch {
            importErrorMessage = userMessage(for: error)
            return nil
        }
    }
}
