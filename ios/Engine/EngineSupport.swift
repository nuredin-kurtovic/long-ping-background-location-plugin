import CoreLocation
import Foundation
import os

/// Event names (DESIGN.md, "Events").
enum EngineEvent: String {
    case location, motionchange, http, providerchange, authorization, enabledchange, configchange, error
}

/// Hands events to the RN bridge. Thread-safe; drops events while no bridge is observing (nothing is
/// buffered for JS by contract).
final class EventSink {
    typealias Handler = (String, [String: Any]) -> Void

    private let lock = NSLock()
    private var handler: Handler?
    private weak var owner: AnyObject?

    func set(_ handler: @escaping Handler, owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        self.owner = owner
    }

    /// Only the module instance that installed the handler can remove it: after a JS reload the old
    /// instance is invalidated after the new one has already subscribed.
    func remove(owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        if self.owner === owner || self.owner == nil {
            handler = nil
            self.owner = nil
        }
    }

    func emit(_ event: EngineEvent, _ body: [String: Any]) {
        lock.lock()
        let handler = owner == nil ? nil : self.handler
        lock.unlock()
        handler?(event.rawValue, body)
    }
}

/// Writes every line to the on-device log (via `LocalStore`, on the io queue) and to the unified log.
final class EngineLogger {
    private let lock = NSLock()
    private var threshold: LogLevel = .info
    private let clock: TimeSource
    private let store: LocalStore
    private let osLog = OSLog(subsystem: "com.longping", category: "LongPing")

    init(clock: TimeSource, store: LocalStore) {
        self.clock = clock
        self.store = store
    }

    var level: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return threshold }
        set { lock.lock(); threshold = newValue; lock.unlock() }
    }

    func error(_ tag: String, _ message: @autoclosure () -> String) { log(.error, tag, message()) }
    func warn(_ tag: String, _ message: @autoclosure () -> String) { log(.warn, tag, message()) }
    func info(_ tag: String, _ message: @autoclosure () -> String) { log(.info, tag, message()) }
    func debug(_ tag: String, _ message: @autoclosure () -> String) { log(.debug, tag, message()) }

    func log(_ level: LogLevel, _ tag: String, _ message: @autoclosure () -> String) {
        guard self.level.allows(level) else { return }
        let entry = LogEntry(time: clock.nowMs, level: level, tag: tag, message: message())
        os_log("%{public}@", log: osLog, type: level.osLogType, "[\(tag)] \(entry.message)")
        store.appendLog(entry)
    }
}

private extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .error: return .error
        case .warn: return .default
        case .info: return .info
        case .debug, .off: return .debug
        }
    }
}

/// Reported in the log at engine start.
enum PluginInfo {
    static let version = "0.1.4"
}

extension Fix {
    /// nil for fixes CoreLocation marks invalid (negative horizontal accuracy).
    init?(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            speed: location.speed >= 0 ? location.speed : -1,
            heading: location.course >= 0 ? location.course : -1,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            time: EpochMs(seconds: location.timestamp.timeIntervalSince1970),
            isMock: location.sourceInformation?.isSimulatedBySoftware ?? false
        )
    }
}

extension Accuracy {
    var clAccuracy: CLLocationAccuracy {
        switch self {
        case .high: return kCLLocationAccuracyBest
        case .balanced: return kCLLocationAccuracyHundredMeters
        case .low: return kCLLocationAccuracyKilometer
        }
    }
}

extension ActivityType {
    var clActivityType: CLActivityType {
        switch self {
        case .automotive: return .automotiveNavigation
        case .otherNavigation: return .otherNavigation
        case .fitness: return .fitness
        case .other: return .other
        }
    }
}

extension CLAuthorizationStatus {
    /// DESIGN.md AuthorizationStatus: 0 NOT_DETERMINED, 1 RESTRICTED, 2 DENIED, 3 ALWAYS, 4 WHEN_IN_USE.
    var contractValue: Int {
        switch self {
        case .notDetermined: return 0
        case .restricted: return 1
        case .denied: return 2
        case .authorizedAlways: return 3
        case .authorizedWhenInUse: return 4
        @unknown default: return 0
        }
    }

    var isAuthorized: Bool { self == .authorizedAlways || self == .authorizedWhenInUse }

    var name: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

enum InfoPlist {
    static func hasBackgroundLocationMode() -> Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
    }

    static func has(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.isEmpty
    }

    static let whenInUseKey = "NSLocationWhenInUseUsageDescription"
    static let alwaysKey = "NSLocationAlwaysAndWhenInUseUsageDescription"
}

/// Whole meters for log lines; tolerant of non-finite input, unlike `Int(_:)`.
func meters(_ value: Double) -> String { String(format: "%.0f", value) }

extension DispatchQueue {
    /// Runs `work` on main now if already there, else async.
    static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// A repeating or one-shot GCD timer on a given queue.
final class EngineTimer {
    private var source: DispatchSourceTimer?
    private let queue: DispatchQueue

    /// Keeps the Double → Int conversion below in range whatever the caller computed.
    private static let maxDelaySec = 7 * 86_400.0

    init(queue: DispatchQueue) { self.queue = queue }

    func schedule(after seconds: Double, repeating: Double? = nil, _ handler: @escaping () -> Void) {
        cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delay = DispatchTimeInterval.milliseconds(Int(min(max(0, seconds), Self.maxDelaySec) * 1000))
        if let repeating {
            timer.schedule(deadline: .now() + delay, repeating: .milliseconds(Int(repeating * 1000)), leeway: .seconds(1))
        } else {
            timer.schedule(deadline: .now() + delay, leeway: .milliseconds(250))
        }
        timer.setEventHandler(handler: handler)
        timer.resume()
        source = timer
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    var isScheduled: Bool { source != nil }

    deinit { source?.cancel() }
}
