import SwiftUI

struct RootView: View {
    let environment: AppEnvironment

    @State private var library: LibraryViewModel
    @State private var login: LoginViewModel
    @State private var chats: ChatPickerViewModel
    @State private var network = NetworkStatus()

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
    }

    var body: some View {
        VStack(spacing: 0) {
            if network.isOffline {
                OfflineBanner()
                    .accessibilityIdentifier("banner.offline")
            }

            TabView {
                NavigationStack {
                    LibraryView(environment: environment, model: library)
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
        .task {
            network.start()
            await environment.prepare()
        }
    }
}
