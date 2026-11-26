import Foundation
import Network
import Observation

/// Reports whether the device currently has a network path, so imported music can
/// be presented as available offline rather than as an error.
@MainActor
@Observable
final class NetworkStatus {
    private(set) var isOffline = false

    private let monitor = NWPathMonitor()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                self?.isOffline = offline
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.musicplayer.network", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }
}
