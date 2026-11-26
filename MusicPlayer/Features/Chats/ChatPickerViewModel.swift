import Foundation
import MusicCore
import Observation

@MainActor
@Observable
final class ChatPickerViewModel {
    private let gateway: any TelegramGateway

    var chats: [TelegramChat] = []
    var query = ""
    var isLoading = false
    var hasLoaded = false
    var errorMessage: String?

    init(gateway: any TelegramGateway) {
        self.gateway = gateway
    }

    var filteredChats: [TelegramChat] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load(force: Bool = false) async {
        guard !isLoading, force || !hasLoaded else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            chats = try await gateway.loadChats()
            hasLoaded = true
        } catch {
            if (error as? DomainError)?.isAuthenticationRelated == true {
                chats = []
                hasLoaded = false
            }
            errorMessage = userMessage(for: error)
        }
    }

    func reload() async {
        hasLoaded = false
        await load(force: true)
    }

    /// Clears cached chats when the Telegram session ends.
    func clear() {
        chats = []
        hasLoaded = false
        errorMessage = nil
        query = ""
    }
}
