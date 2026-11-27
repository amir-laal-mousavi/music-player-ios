import Foundation
import MusicCore
import MusicLibrary
import SwiftData
import TelegramClient

/// Owns the long-lived services the screens share.
@MainActor
final class AppEnvironment {
    let configuration: AppConfiguration?
    let gateway: any TelegramGateway
    let store: any LibraryStore
    let fileStore: LibraryFileStore
    let artworkStore: ArtworkStore
    let equalizer: EqualizerStore
    let coordinator: ImportCoordinator
    let player: any PlayerEngine
    let isUITesting: Bool

    init(
        configuration: AppConfiguration?,
        gateway: any TelegramGateway,
        store: any LibraryStore,
        fileStore: LibraryFileStore,
        artworkStore: ArtworkStore,
        equalizer: EqualizerStore,
        player: any PlayerEngine,
        isUITesting: Bool
    ) {
        self.configuration = configuration
        self.gateway = gateway
        self.store = store
        self.fileStore = fileStore
        self.artworkStore = artworkStore
        self.equalizer = equalizer
        self.player = player
        self.isUITesting = isUITesting
        self.coordinator = ImportCoordinator(
            gateway: gateway,
            store: store,
            fileStore: fileStore,
            artworkStore: artworkStore
        )
    }

    var isTelegramConfigured: Bool { configuration != nil }

    /// Restores the durable import queue and clears files that no track references.
    func prepare() async {
        do {
            try await coordinator.recover()
        } catch {
            // A failed recovery must not block offline playback of already imported music.
        }
        do {
            try await fileStore.cleanupPartials()
        } catch {
            // Partial downloads are retried by the import queue.
        }
    }

    static func make(uiTesting: Bool) throws -> AppEnvironment {
        #if DEBUG
        if uiTesting {
            return try makeStub()
        }
        #endif
        return try makeLive()
    }

    private static func makeLive() throws -> AppEnvironment {
        let container = try SwiftDataLibraryStore.makeContainer()
        let store = SwiftDataLibraryStore(container: container)
        let fileStore = try LibraryFileStore()
        let artworkStore = try ArtworkStore()
        let equalizer = EqualizerStore()
        let player = try AVFoundationPlayerEngine(equalizer: equalizer.settings)

        let configuration: AppConfiguration?
        let gateway: any TelegramGateway
        switch AppConfiguration.load() {
        case .success(let value):
            configuration = value
            gateway = try TelegramGatewayClient(
                apiID: value.apiID,
                apiHash: value.apiHash,
                downloadDirectory: try TelegramPaths.downloadsDirectory()
            )
        case .failure:
            configuration = nil
            gateway = UnavailableTelegramGateway()
        }

        return AppEnvironment(
            configuration: configuration,
            gateway: gateway,
            store: store,
            fileStore: fileStore,
            artworkStore: artworkStore,
            equalizer: equalizer,
            player: player,
            isUITesting: false
        )
    }

    #if DEBUG
    /// A deterministic, offline environment used by UI tests.
    private static func makeStub() throws -> AppEnvironment {
        let container = try SwiftDataLibraryStore.makeContainer(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBitUITests-\(UUID().uuidString)", isDirectory: true)
        let fileStore = try LibraryFileStore(directory: directory)
        return AppEnvironment(
            configuration: AppConfiguration(apiID: 1, apiHash: "ui-testing"),
            gateway: StubTelegramGateway(),
            store: SwiftDataLibraryStore(container: container),
            fileStore: fileStore,
            artworkStore: try ArtworkStore(
                directory: directory.appendingPathComponent("Artwork", isDirectory: true)
            ),
            equalizer: EqualizerStore(),
            player: try AVFoundationPlayerEngine(),
            isUITesting: true
        )
    }
    #endif
}

/// Stands in when Telegram credentials are missing so the rest of the app still works.
struct UnavailableTelegramGateway: TelegramGateway {
    var authState: TelegramAuthState { .unauthenticated }
    var currentAccount: TelegramAccount? { nil }

    func observeAuthState() -> AsyncStream<TelegramAuthState> {
        AsyncStream { continuation in
            continuation.yield(.unauthenticated)
            continuation.finish()
        }
    }

    func submitPhone(_ phone: String) async throws { throw DomainError.telegram(.serviceUnavailable) }
    func submitCode(_ code: String) async throws { throw DomainError.telegram(.serviceUnavailable) }
    func submitPassword(_ password: String) async throws { throw DomainError.telegram(.serviceUnavailable) }
    func logout() async throws {}

    func loadChats() async throws -> [TelegramChat] {
        throw DomainError.telegram(.serviceUnavailable)
    }

    func loadAudioMessages(_ request: TelegramAudioPageRequest) async throws -> TelegramAudioPage {
        throw DomainError.telegram(.serviceUnavailable)
    }

    func downloadAudio(
        _ audio: TelegramAudio,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        throw DomainError.telegram(.serviceUnavailable)
    }

    func cancelDownload(for identity: TelegramAudioIdentity) async {}
}
