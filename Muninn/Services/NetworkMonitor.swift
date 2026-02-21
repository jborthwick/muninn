import Foundation
import Network

/// Monitors network connectivity status
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Actual network status from NWPathMonitor
    private var actuallyConnected = true
    private(set) var connectionType: ConnectionType = .unknown

    /// Simulated offline mode for testing
    var simulateOffline = false

    /// Returns true if connected (respects simulated offline mode)
    var isConnected: Bool {
        simulateOffline ? false : actuallyConnected
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    enum ConnectionType {
        case wifi
        case cellular
        case wired
        case unknown
    }

    private init() {
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.actuallyConnected = path.status == .satisfied
                self?.connectionType = self?.getConnectionType(path) ?? .unknown
            }
        }
        monitor.start(queue: queue)
    }

    private func getConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        } else {
            return .unknown
        }
    }

    deinit {
        monitor.cancel()
    }
}
