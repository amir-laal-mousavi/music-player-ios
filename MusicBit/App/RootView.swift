import MusicCore
import MusicLibrary
import SwiftUI

enum AppTab: Hashable {
    case library
    case playlists
    case telegram
    case importFiles
    case search
}

struct RootView: View {
    let environment: AppEnvironment

    @State private var library: LibraryViewModel
    @State private var login: LoginViewModel
    @State private var chats: ChatPickerViewModel
    @State private var fileImport: FileImportViewModel
    @State private var playback: NowPlayingViewModel
    @State private var playlists: PlaylistsViewModel
    @State private var equalizer: EqualizerStore
    @State private var network = NetworkStatus()

    @State private var selectedTab: AppTab = .library
    @State private var isPlayerPresented = false

    init(environment: AppEnvironment) {
        self.environment = environment
        _library = State(
            initialValue: LibraryViewModel(
                store: environment.store,
                coordinator: environment.coordinator,
                player: environment.player
            )
        )
        _login = State(initialValue: LoginViewModel(gateway: environment.gateway))
        _chats = State(initialValue: ChatPickerViewModel(gateway: environment.gateway))
        _fileImport = State(
            initialValue: FileImportViewModel(
                importer: LocalFileImporter(
                    store: environment.store,
                    fileStore: environment.fileStore,
                    artworkStore: environment.artworkStore
                )
            )
        )
        _playback = State(
            initialValue: NowPlayingViewModel(
                player: environment.player,
                tracks: [],
                startingIndex: 0
            )
        )
        _playlists = State(initialValue: PlaylistsViewModel(store: environment.store))
        _equalizer = State(initialValue: environment.equalizer)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "music.note.list", value: AppTab.library) {
                NavigationStack {
                    LibraryView(
                        environment: environment,
                        model: library,
                        playlists: playlists,
                        onPlay: play
                    )
                }
            }

            Tab("Playlists", systemImage: "rectangle.stack", value: AppTab.playlists) {
                NavigationStack {
                    PlaylistsView(model: playlists) { tracks, index in
                        play(NowPlayingRequest(tracks: tracks, startingIndex: index))
                    }
                }
            }

            Tab("Telegram", systemImage: "paperplane", value: AppTab.telegram) {
                NavigationStack {
                    TelegramTabView(
                        environment: environment,
                        login: login,
                        chats: chats,
                        onSignOut: {
                            chats.clear()
                            Task { await login.logout() }
                        }
                    )
                }
            }

            Tab("Import", systemImage: "square.and.arrow.down", value: AppTab.importFiles) {
                NavigationStack {
                    ImportView(model: fileImport)
                }
            }

            // The search role makes iOS separate it into the round button at the
            // trailing end of the tab bar, the way Music does it.
            Tab(value: AppTab.search, role: .search) {
                NavigationStack {
                    LibrarySearchView(model: library, onPlay: play)
                }
            }
        }
        .miniPlayerAccessory(isVisible: playback.currentTrack != nil) {
            MiniPlayerView(model: playback) {
                isPlayerPresented = true
            }
        }
        .sheet(isPresented: $isPlayerPresented) {
            NowPlayingView(
                model: playback,
                equalizer: equalizer,
                isFavorite: { library.isFavorite($0) },
                onToggleFavorite: { track in
                    Task { await library.toggleFavorite(track) }
                }
            )
        }
        .onOpenURL { url in
            // Another app ("Open in MusicBit") or Files handed us audio to import.
            guard url.isFileURL else { return }
            selectedTab = .importFiles
            fileImport.importFiles([url])
        }
        .onChange(of: fileImport.isImporting) { _, importing in
            if importing { selectedTab = .importFiles }
        }
        .task {
            network.start()
            await playback.applyEqualizer(equalizer.settings)
            await playback.start()
            await environment.prepare()
        }
    }

    private func play(_ request: NowPlayingRequest) {
        isPlayerPresented = true
        Task {
            await playback.load(request.tracks, startingAt: request.startingIndex)
        }
    }
}

private extension View {
    /// Docks the mini player in the tab view's bottom accessory, the system slot
    /// above the tab bar, so it never covers the tab bar itself.
    @ViewBuilder
    func miniPlayerAccessory<Accessory: View>(
        isVisible: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isVisible, content: accessory)
        } else {
            // Before 26.1 an empty accessory hides itself; 26.1 needs isEnabled.
            tabViewBottomAccessory {
                if isVisible { accessory() }
            }
        }
    }
}
