import Foundation
import UIKit

/// Native entry point. The React Native bridge (LongPing.mm) forwards every call here; host apps can also
/// call it directly. Thread-safe: work hops to the main thread (CoreLocation, engine state) or the io queue
/// (sqlite, Keychain, uploads). Completions may arrive on any thread.
///
/// Completion contract: `(result, errorCode, errorMessage)`. `errorCode` non-nil = reject with a DESIGN.md
/// error code; otherwise resolve with `result` (nil = void).
@objc(LongPingEngine)
public final class LongPingEngine: NSObject {
    public typealias Completion = (Any?, String?, String?) -> Void
    public typealias EventHandler = (String, [String: Any]) -> Void

    @objc public static let shared = LongPingEngine()

    private let clock: TimeSource = SystemClock()
    private let ioQueue = DispatchQueue(label: "com.longping.io", qos: .utility)
    private let store: LocalStore
    private let logger: EngineLogger
    private let events = EventSink()
    private let preferences = Preferences()
    private let auth: AuthCache
    private let uploader: Uploader
    private let network: NetworkMonitor
    private var tracker: Tracker?
    private var unlockObserver: NSObjectProtocol?

    override private init() {
        store = LocalStore(queue: ioQueue)
        logger = EngineLogger(clock: clock, store: store)
        auth = AuthCache(keychain: KeychainAuthStore(), logger: logger)
        uploader = Uploader(queue: ioQueue, store: store, auth: auth, logger: logger, events: events, clock: clock)
        network = NetworkMonitor(queue: ioQueue)
        super.init()
        uploader.onRemoteCommand = { [weak self] command in
            DispatchQueue.main.async { self?.tracker?.applyRemote(command) }
        }
        uploader.onAuthorizationRequiredChange = { [weak self] required in
            DispatchQueue.main.async { self?.tracker?.setAuthorizationRequired(required) }
        }
        network.onAvailable = { [weak self] in self?.uploader.connectivityRestored() }
    }

    // MARK: - Launch

    /// Called at every app launch (LongPing.mm `+load` observes didFinishLaunching), including background
    /// relaunches by region / significant-change monitoring. Restarts tracking if it was enabled — no JS needed.
    @objc public func resumeIfEnabled() {
        DispatchQueue.onMain {
            guard self.canReadPreferences else { return self.waitForProtectedData() }
            self.bootstrap().resume()
        }
    }

    /// Before the first unlock after a reboot UserDefaults reads come back empty, which would look like
    /// "never enabled". The install marker tells a real empty store from an unreadable one.
    private var canReadPreferences: Bool {
        UIApplication.shared.isProtectedDataAvailable || !preferences.isFirstLaunchAfterInstall
    }

    private func waitForProtectedData() {
        guard unlockObserver == nil else { return }
        logger.info("engine", "launched before the first unlock: resuming once the device is unlocked")
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let observer = self.unlockObserver { NotificationCenter.default.removeObserver(observer) }
            self.unlockObserver = nil
            self.resumeIfEnabled()
        }
    }

    /// Creates the tracker on first use. Main thread.
    private func bootstrap() -> Tracker {
        if let tracker { return tracker }
        if UIApplication.shared.isProtectedDataAvailable, preferences.isFirstLaunchAfterInstall {
            // Keychain items survive an uninstall; never send a previous install's token.
            ioQueue.async { [auth] in auth.clear() }
            preferences.markInstalled()
        }
        let tracker = Tracker(clock: clock, logger: logger, events: events, preferences: preferences, store: store,
                              uploader: uploader)
        self.tracker = tracker
        network.start()
        logger.info("engine", "engine ready (Long Ping \(PluginInfo.version), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion))")
        return tracker
    }

    // MARK: - Events

    /// The bridge installs this while JS listeners exist. Events are dropped otherwise (never buffered).
    @objc(setEventSink:owner:)
    public func setEventSink(_ sink: @escaping EventHandler, owner: AnyObject) {
        events.set(sink, owner: owner)
    }

    @objc(removeEventSinkForOwner:)
    public func removeEventSink(owner: AnyObject) {
        events.remove(owner: owner)
    }

    // MARK: - Config and lifecycle

    @objc(configure:completion:)
    public func configure(_ config: [String: Any]?, completion: @escaping Completion) {
        applyConfig(config, merge: false, source: "configure()", completion: completion)
    }

    @objc(setConfig:completion:)
    public func setConfig(_ config: [String: Any]?, completion: @escaping Completion) {
        applyConfig(config, merge: true, source: "setConfig()", completion: completion)
    }

    private func applyConfig(_ config: [String: Any]?, merge: Bool, source: String, completion: @escaping Completion) {
        let patch = JSONValue(foundation: config)
        onMain(completion) { tracker in
            guard let patch else { throw LongPingError(.invalidConfig, "config contains values that are not JSON") }
            try tracker.applyConfig(patch, merge: merge, source: source)
            self.resolveState(tracker, completion)
        }
    }

    @objc(startWithCompletion:)
    public func start(completion: @escaping Completion) {
        onMain(completion) { tracker in
            tracker.start { error in
                if let error {
                    self.logger.warn("engine", "start() rejected: \(error.code.rawValue) \(error.message)")
                    return completion(nil, error.code.rawValue, error.message)
                }
                self.resolveState(tracker, completion)
            }
        }
    }

    @objc(stopWithCompletion:)
    public func stop(completion: @escaping Completion) {
        onMain(completion) { tracker in
            tracker.stop(reason: "stop()")
            self.resolveState(tracker, completion)
        }
    }

    @objc(getStateWithCompletion:)
    public func getState(completion: @escaping Completion) {
        onMain(completion) { tracker in self.resolveState(tracker, completion) }
    }

    @objc(changePace:completion:)
    public func changePace(_ isMoving: Bool, completion: @escaping Completion) {
        onMain(completion) { tracker in
            try tracker.changePace(isMoving)
            self.resolveState(tracker, completion)
        }
    }

    // MARK: - Authorization

    @objc(setAuthorization:completion:)
    public func setAuthorization(_ authorization: [String: Any]?, completion: @escaping Completion) {
        let json = JSONValue(foundation: authorization)
        onMain(completion) { tracker in
            guard let json else { throw LongPingError(.invalidConfig, "authorization must be an object") }
            let credentials = try AuthCredentials(json: json)
            tracker.setAuthorizationRequired(false)
            self.ioQueue.async {
                self.auth.store(credentials)
                self.logger.info("auth", "credentials stored\(credentials.canRefresh ? " (with refresh URL)" : "")")
                self.uploader.authorizationChanged(cleared: false)
                completion(nil, nil, nil)
            }
        }
    }

    @objc(clearAuthorizationWithCompletion:)
    public func clearAuthorization(completion: @escaping Completion) {
        ioQueue.async {
            self.auth.clear()
            self.logger.info("auth", "credentials cleared")
            completion(nil, nil, nil)
        }
    }

    // MARK: - Locations and queue

    @objc(getCurrentPosition:completion:)
    public func getCurrentPosition(_ options: [String: Any]?, completion: @escaping Completion) {
        let parsed = CurrentPositionOptions(JSONValue(foundation: options))
        onMain(completion) { tracker in
            tracker.getCurrentPosition(parsed) { result in
                switch result {
                case .success(let location): completion(location, nil, nil)
                case .failure(let error): completion(nil, error.code.rawValue, error.message)
                }
            }
        }
    }

    @objc(syncWithCompletion:)
    public func sync(completion: @escaping Completion) {
        onMain(completion) { _ in
            self.uploader.sync { uploaded in completion(uploaded, nil, nil) }
        }
    }

    @objc(getQueueCountWithCompletion:)
    public func getQueueCount(completion: @escaping Completion) {
        store.queueCount { completion($0, nil, nil) }
    }

    @objc(clearQueueWithCompletion:)
    public func clearQueue(completion: @escaping Completion) {
        store.clearQueue { result in
            switch result {
            case .success(let deleted):
                self.logger.info("queue", "clearQueue(): deleted \(deleted) record(s)")
                completion(nil, nil, nil)
            case .failure(let error):
                completion(nil, ErrorCode.internalError.rawValue, "\(error)")
            }
        }
    }

    // MARK: - Permission and settings

    @objc(getProviderStateWithCompletion:)
    public func getProviderState(completion: @escaping Completion) {
        onMain(completion) { tracker in tracker.providerState { completion($0, nil, nil) } }
    }

    @objc(requestPermission:completion:)
    public func requestPermission(_ level: String, completion: @escaping Completion) {
        onMain(completion) { tracker in
            guard let parsed = PermissionFlow.Level(rawValue: level) else {
                throw LongPingError(.invalidConfig, "level must be 'whenInUse' or 'always'")
            }
            tracker.requestPermission(parsed) { completion($0, nil, nil) }
        }
    }

    /// Both settings calls open the app's page in Settings (iOS has no deep link to Location Services).
    @objc(openAppSettingsWithCompletion:)
    public func openAppSettings(completion: @escaping Completion) {
        DispatchQueue.onMain {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return completion(false, nil, nil) }
            UIApplication.shared.open(url, options: [:]) { opened in completion(opened, nil, nil) }
        }
    }

    @objc(openLocationSettingsWithCompletion:)
    public func openLocationSettings(completion: @escaping Completion) {
        openAppSettings(completion: completion)
    }

    // MARK: - Log

    @objc(getLog:completion:)
    public func getLog(_ options: [String: Any]?, completion: @escaping Completion) {
        let query = LogQuery(JSONValue(foundation: options), now: clock.nowMs)
        store.logText(since: query.sinceMs, limit: query.limit, ascending: query.ascending) { result in
            switch result {
            case .success(let text): completion(text, nil, nil)
            case .failure(let error): completion(nil, ErrorCode.internalError.rawValue, "\(error)")
            }
        }
    }

    @objc(clearLogWithCompletion:)
    public func clearLog(completion: @escaping Completion) {
        store.clearLog { result in
            switch result {
            case .success: completion(nil, nil, nil)
            case .failure(let error): completion(nil, ErrorCode.internalError.rawValue, "\(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Runs `body` on main with the tracker; thrown errors reject with their code.
    private func onMain(_ completion: @escaping Completion, _ body: @escaping (Tracker) throws -> Void) {
        DispatchQueue.onMain {
            do {
                try body(self.bootstrap())
            } catch let error as LongPingError {
                completion(nil, error.code.rawValue, error.message)
            } catch let error as ConfigError {
                completion(nil, ErrorCode.invalidConfig.rawValue, error.description)
            } catch {
                completion(nil, ErrorCode.internalError.rawValue, "\(error)")
            }
        }
    }

    /// State needs the queue count from the io queue; built on main after it.
    private func resolveState(_ tracker: Tracker, _ completion: @escaping Completion) {
        store.queueCount { count in
            DispatchQueue.main.async { completion(tracker.stateDictionary(queueCount: count), nil, nil) }
        }
    }
}
