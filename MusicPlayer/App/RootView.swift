import MusicLibrary
import SwiftUI

struct RootView: View {
    let environment: AppEnvironment

    @State private var library: LibraryViewModel
    @State private var login: LoginViewModel
    @State private var chats: ChatPickerViewModel
    @State private var fileImport: FileImportViewModel
    @State private var network = NetworkStatus()
    @State private var isShowingImportSheet = false

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
                    fileStore: environment.fileStore
                )
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if network.isOffline {
                OfflineBanner()
                    .accessibilityIdentifier("banner.offline")
            }

            TabView {
                NavigationStack {
                    LibraryView(
                        environment: environment,
                        model: library,
                        importModel: fileImport
                    )
                }
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

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
            }
        }
        .sheet(isPresented: $isShowingImportSheet, onDismiss: { fileImport.dismiss() }) {
            FileImportSheet(model: fileImport)
        }
        .onChange(of: fileImport.isPresentingStatus) { _, isPresenting in
            if isPresenting {
                // Let the document picker finish dismissing before presenting progress.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if fileImport.isPresentingStatus {
                        isShowingImportSheet = true
                    }
                }
            } else {
                isShowingImportSheet = false
            }
        }
        .onOpenURL { url in
            // Another app ("Open in MusicPlayer") or Files handed us audio to import.
            guard url.isFileURL else { return }
            fileImport.importFiles([url])
        }
        .task {
            network.start()
            await environment.prepare()
        }
    }
}
