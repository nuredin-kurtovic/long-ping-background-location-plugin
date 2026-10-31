import Foundation
import Network
import UIKit

/// Battery level and charging state. Main thread only.
final class BatteryMonitor {
    private(set) var snapshot: BatterySnapshot = .unknown
    var onChange: ((BatterySnapshot) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }

    private func refresh() {
        let device = UIDevice.current
        let level = device.batteryLevel
        let state = device.batteryState
        let next = BatterySnapshot(level: level < 0 ? -1 : Double(level), isCharging: state == .charging || state == .full)
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Connectivity via NWPathMonitor. Callbacks run on the given queue.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue: DispatchQueue
    private var wasSatisfied: Bool?
    /// Called when the path becomes usable (including the first report if it already is).
    var onAvailable: (() -> Void)?
    var onChange: ((Bool) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let previous = self.wasSatisfied
            self.wasSatisfied = satisfied
            guard previous != satisfied else { return }
            self.onChange?(satisfied)
            if satisfied { self.onAvailable?() }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
