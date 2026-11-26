import MusicCore
import MusicLibrary
import SwiftUI

enum AppTab: Hashable {
    case library
    case telegram
    case importFiles
}

struct RootView: View {
    let environment: AppEnvironment

    @State private var library: LibraryViewModel
    @State private var login: LoginViewModel
    @State private var chats: ChatPickerViewModel
    @State private var fileImport: FileImportViewModel
    @State private var playback: NowPlayingViewModel
    @State private var network = NetworkStatus()

    @State private var selectedTab: AppTab = .library
    @State private var isSearchPresented = false
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
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView(
                    environment: environment,
                    model: library,
                    isSearchPresented: $isSearchPresented,
                    onPlay: play
                )
            }
            .tabItem {
                Label("Library", systemImage: "music.note.list")
            }
            .tag(AppTab.library)

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
            .tabItem {
                Label("Telegram", systemImage: "paperplane")
            }
            .tag(AppTab.telegram)

            NavigationStack {
                ImportView(model: fileImport)
            }
            .tabItem {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .tag(AppTab.importFiles)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .sheet(isPresented: $isPlayerPresented) {
            NowPlayingView(model: playback)
        }
        .onOpenURL { url in
            // Another app ("Open in MusicPlayer") or Files handed us audio to import.
            guard url.isFileURL else { return }
            selectedTab = .importFiles
            fileImport.importFiles([url])
        }
        .onChange(of: fileImport.isImporting) { _, importing in
            if importing { selectedTab = .importFiles }
        }
        .task {
            network.start()
            await playback.start()
            await environment.prepare()
        }
    }

    /// Mini player plus the circular search button, sitting right above the tab bar.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if playback.currentTrack != nil {
                MiniPlayerView(model: playback) {
                    isPlayerPresented = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                selectedTab = .library
                isSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    }
            }
            .accessibilityLabel("Search library")
            .accessibilityIdentifier("bar.search")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.25), value: playback.currentTrack?.id)
    }

    private func play(_ request: NowPlayingRequest) {
        isPlayerPresented = true
        Task {
            await playback.load(request.tracks, startingAt: request.startingIndex)
        }
    }
}
