import SwiftUI

struct TelegramTabView: View {
    let environment: AppEnvironment
    @Bindable var login: LoginViewModel
    @Bindable var chats: ChatPickerViewModel
    let onSignOut: () -> Void

    var body: some View {
        Group {
            if !environment.isTelegramConfigured {
                TelegramSetupView()
            } else if login.isAuthenticated {
                ChatPickerView(
                    environment: environment,
                    model: chats,
                    account: login.account,
                    onSignOut: onSignOut
                )
            } else {
                LoginView(model: login)
            }
        }
        .navigationTitle(login.isAuthenticated ? "Telegram" : "Sign in")
        .navigationBarTitleDisplayMode(login.isAuthenticated ? .large : .inline)
        .musicBarBackground()
        .task { await login.start() }
    }
}

struct TelegramSetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ContentUnavailableView {
                    Label("Telegram is not configured", systemImage: "key.slash")
                } description: {
                    Text("MusicPlayer needs the api_id and api_hash of your own Telegram application. They are read from build configuration and never stored in the repository.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("To enable sign-in")
                        .font(.headline)
                    Text("1. Create an application at my.telegram.org/apps.")
                    Text("2. Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig.")
                    Text("3. Fill in TELEGRAM_API_ID and TELEGRAM_API_HASH, then build again.")
                    Text("Until then you can import audio files from the Library tab.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassCard()
            }
            .padding(20)
        }
        .background(Theme.background)
        .accessibilityIdentifier("telegram.setup")
    }
}
