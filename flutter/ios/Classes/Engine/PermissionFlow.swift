import CoreLocation
import UIKit

/// `requestPermission(level)`: when-in-use first, then always, resolving once the status settles.
/// Main thread only.
///
/// iOS gives no callback when it decides not to show a prompt (already asked, "Allow Once", app in the
/// background), so "settled" also means: no prompt appeared within a short window, or the app became
/// active again after the prompt was dismissed.
final class PermissionFlow {
    enum Level: String {
        case whenInUse, always
    }

    private enum Stage: Equatable {
        case idle
        case awaitingWhenInUse
        case awaitingAlways
    }

    /// How long to wait for a prompt to take the app inactive before concluding none was shown.
    private static let promptGraceSec = 2.0
    /// After the app becomes active again, give the authorization callback this long to arrive.
    private static let settleSec = 1.0

    private let location: LocationController
    private let logger: EngineLogger
    private var stage: Stage = .idle
    private var target: Level = .whenInUse
    private var waiters: [(Int) -> Void] = []
    private var promptShown = false
    /// Invalidates timers scheduled for an earlier stage.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    init(location: LocationController, logger: EngineLogger) {
        self.location = location
        self.logger = logger
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.promptShown = true
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appBecameActive()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func request(_ level: Level, completion: @escaping (Int) -> Void) {
        waiters.append(completion)
        if level == .always { target = .always }
        guard stage == .idle else { return }
        if level == .whenInUse { target = .whenInUse }
        advance(location.authorizationStatus)
    }

    func authorizationDidChange(_ status: CLAuthorizationStatus) {
        switch stage {
        case .idle:
            return
        case .awaitingWhenInUse:
            // CoreLocation also reports the unchanged status when a manager is created; wait for an answer.
            guard status != .notDetermined else { return }
            advance(status)
        case .awaitingAlways:
            if status != .authorizedWhenInUse { finish(status) }
        }
    }

    private func advance(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            guard InfoPlist.has(InfoPlist.whenInUseKey) else {
                logger.error("permission", "Info.plist lacks \(InfoPlist.whenInUseKey); iOS will not show the prompt")
                return finish(status)
            }
            enter(.awaitingWhenInUse)
            location.requestWhenInUse()
        case .authorizedWhenInUse where target == .always && stage != .awaitingAlways:
            guard InfoPlist.has(InfoPlist.alwaysKey) else {
                logger.error("permission", "Info.plist lacks \(InfoPlist.alwaysKey); iOS will not show the 'Always' prompt")
                return finish(status)
            }
            enter(.awaitingAlways)
            location.requestAlways()
        default:
            finish(status)
        }
    }

    private func enter(_ next: Stage) {
        stage = next
        promptShown = false
        generation += 1
        let token = generation
        logger.info("permission", "requesting \(next == .awaitingAlways ? "always" : "whenInUse") authorization")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptGraceSec) { [weak self] in
            guard let self, self.generation == token, self.stage != .idle, !self.promptShown else { return }
            self.logger.info("permission", "no prompt shown; status stays \(self.location.authorizationStatus.name)")
            self.finish(self.location.authorizationStatus)
        }
    }

    private func appBecameActive() {
        guard stage != .idle, promptShown else { return }
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSec) { [weak self] in
            guard let self, self.generation == token, self.stage != .idle else { return }
            let status = self.location.authorizationStatus
            if self.stage == .awaitingWhenInUse, status != .notDetermined {
                self.advance(status)
            } else {
                self.finish(status)
            }
        }
    }

    private func finish(_ status: CLAuthorizationStatus) {
        stage = .idle
        generation += 1
        target = .whenInUse
        let pending = waiters
        waiters.removeAll()
        logger.info("permission", "authorization settled: \(status.name)")
        pending.forEach { $0(status.contractValue) }
    }
}
