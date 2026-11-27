import SwiftUI

@main
struct MusicBitApp: App {
    @State private var boot: Result<AppEnvironment, Error>

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        boot = Result { try AppEnvironment.make(uiTesting: isUITesting) }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch boot {
                case .success(let environment):
                    RootView(environment: environment)
                case .failure(let error):
                    BootFailureView(message: error.localizedDescription)
                }
            }
            .tint(Theme.accent)
        }
    }
}

struct BootFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("MusicBit cannot start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .padding()
    }
}
