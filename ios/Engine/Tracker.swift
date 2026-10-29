import CoreLocation
import UIKit

/// The engine's state machine: config, moving/parked, the recording clock, the location manager plan,
/// the watchdog and app lifecycle. Main thread only. Decisions come from Core; this type wires them to
/// CoreLocation, storage and events.
final class Tracker: LocationControllerDelegate {
    private let clock: TimeSource
    private let logger: EngineLogger
    private let events: EventSink
    private let preferences: Preferences
    private let store: LocalStore
    private let uploader: Uploader
    private let battery = BatteryMonitor()
    private let location: LocationController
    private let permissions: PermissionFlow

    /// The app's config and the server's overrides; `config` is the effective result.
    private var layers: ConfigLayers
    var config: LongPingConfig { layers.effective }
    private var state: PersistedEngineState
    private var detector: StopDetector
    private var gate: RecordingGate
    private var pendingMotion: PendingMotionChange?
    /// Most recent fix from any source (also while stopped, via getCurrentPosition).
    private var lastFix: Fix?

    private var trackingActive = false
    private var trackingStartedAt: EpochMs = 0
    private var lastRestartAt: EpochMs = 0
    private var samplingMode: SamplingPlan.Mode = .configured
    private let samplingTimer = EngineTimer(queue: .main)
    private let watchdogTimer = EngineTimer(queue: .main)
    /// Center + radius of the region we asked CoreLocation to monitor.
    private var monitoredRegion: (latitude: Double, longitude: Double, radius: Double)?
    private var currentRequests: [CurrentPositionRequest] = []
    private var lastAuthorization: CLAuthorizationStatus?
    private var lastFullAccuracy: Bool?
    private var lastStatePersistAt: EpochMs = 0
    private var lastLogPruneAt: EpochMs = 0
    private var inaccurateSinceRecord = 0
    private var observers: [NSObjectProtocol] = []

    private static let statePersistIntervalMs: EpochMs = 15_000
    private static let logPruneIntervalMs: EpochMs = 3_600_000

    init(clock: TimeSource, logger: EngineLogger, events: EventSink, preferences: Preferences, store: LocalStore,
         uploader: Uploader) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.clock = clock
        self.logger = logger
        self.events = events
        self.preferences = preferences
        self.store = store
        self.uploader = uploader

        var localConfig = LongPingConfig.defaults
        var configProblem: String?
        if let stored = preferences.loadConfigJSON() {
            do {
                localConfig = try ConfigResolver.resolve(stored).config
            } catch {
                configProblem = "stored config unreadable (\(error)); using defaults"
            }
        }
        let restored = ConfigLayers.restore(local: localConfig, overrides: preferences.loadRemoteOverrides())
        layers = restored.layers
        let persisted = preferences.loadState()
        state = persisted
        detector = StopDetector(isMoving: persisted.isMoving, anchor: persisted.anchor, parkedAt: persisted.parkedAt)
        let now = clock.nowMs
        let resumeAt = RecordingGate.resumeTime(persisted: persisted.lastRecordedTime, newestQueued: store.newestQueuedRecordedAt(),
                                                lastLocationAt: persisted.lastLocationAt, now: now)
        gate = RecordingGate(lastRecordedTime: resumeAt, armedAt: now)
        state.lastRecordedTime = resumeAt

        let location = LocationController(logger: logger)
        self.location = location
        permissions = PermissionFlow(location: location, logger: logger)

        logger.level = config.logLevel
        if let configProblem { logger.error("config", configProblem) }
        if let dropped = restored.dropped {
            preferences.saveRemoteOverrides(layers.overrides)
            logger.error("config", "server overrides cleared: they do not validate with the stored config (\(dropped))")
        }
        if let resumeAt, resumeAt != persisted.lastRecordedTime {
            logger.debug("location", "interval clock resumes from \(Timestamp.iso8601(resumeAt)) (newest stored record or last location)")
        }
        location.delegate = self
        uploader.update(http: config.http)

        battery.onChange = { [weak self] snapshot in self?.batteryChanged(snapshot) }
        battery.start()
        observeLifecycle()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - Lifecycle

    /// Native resume (app launch, including background relaunches by region / significant change).
    func resume() {
        guard state.enabled else {
            logger.debug("engine", "launch: tracking not enabled")
            return
        }
        let status = location.authorizationStatus
        guard status.isAuthorized else {
            logger.warn("engine", "launch: enabled but location permission is \(status.name); waiting for permission")
            events.emit(.error, ["code": ErrorCode.permissionDenied.rawValue,
                                 "message": "tracking is enabled but location permission is \(status.name)"])
            return
        }
        beginTracking(reason: "app launch")
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appWillTerminate()
        })
        observers.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.emitProviderChange()
        })
    }

    private func appWillTerminate() {
        guard state.enabled else { return }
        if config.stopOnTerminate {
            stop(reason: "app terminated (stopOnTerminate)")
            return
        }
        location.startSignificantChanges()
        if detector.isMoving, let fix = lastFix {
            // A region around the last position relaunches the app sooner than significant-change (~500 m)
            // once the user drives off; it is removed again when tracking resumes.
            location.monitorParkedRegion(latitude: fix.latitude, longitude: fix.longitude, radius: parkedRegionRadius)
        } else {
            reconcileRegion()
        }
        syncDetectorState()
        persistState(force: true)
        logger.info("engine", "app terminating: significant-change and region monitoring stay on to relaunch it")
    }

    // MARK: - Config

    /// configure() (merge false: defaults + patch) and setConfig() (merge true), on the app's layer. The server's
    /// overrides stay on top.
    @discardableResult
    func applyConfig(_ patch: JSONValue, merge: Bool, source: String) throws -> LongPingConfig {
        let previous = config
        let change = try layers.setLocal(patch, merge: merge)
        preferences.save(layers.local)
        logger.level = config.logLevel
        log(change.notes)
        logger.info("config", "\(source) applied")
        if let dropped = change.droppedOverrides {
            preferences.saveRemoteOverrides(layers.overrides)
            logger.error("config", "server overrides cleared: they do not validate with this config (\(dropped))")
        }
        uploader.update(http: config.http)
        applyLive(previous: previous)
        return config
    }

    private func log(_ notes: [ConfigResolver.Note]) {
        for note in notes {
            logger.log(note.kind == .unknownKey ? .debug : .warn, "config", note.message)
        }
    }

    private func applyLive(previous: LongPingConfig) {
        guard state.enabled else { return }
        guard trackingActive else {
            if location.authorizationStatus.isAuthorized { beginTracking(reason: "config") }
            return
        }
        if config.disableStopDetection, !detector.isMoving {
            detector.forceMoving(at: nil)
            syncDetectorState()
            requestMotionChange()
        }
        reconcileRegion()
        updateSampling()
        if IntervalPolicy.effectiveInterval(isMoving: detector.isMoving, config: previous, battery: battery.snapshot) != effectiveInterval {
            logger.info("engine", "interval now \(JSONValue.format(effectiveInterval)) s")
        }
    }

    // MARK: - start / stop / changePace

    func start(_ completion: @escaping (LongPingError?) -> Void) {
        let status = location.authorizationStatus
        guard status.isAuthorized else {
            return completion(LongPingError(.permissionDenied, "location permission is \(status.name); call requestPermission() first"))
        }
        Self.checkServicesEnabled { [weak self] enabled in
            guard let self else { return }
            guard enabled else {
                return completion(LongPingError(.locationServicesOff, "Location Services are turned off"))
            }
            self.enable()
            completion(nil)
        }
    }

    private func enable() {
        guard !state.enabled else {
            logger.info("engine", "start(): already enabled")
            beginTracking(reason: "start")
            return
        }
        state.enabled = true
        detector.forceMoving(at: nil)
        gate.rearm(now: clock.nowMs)
        syncDetectorState()
        persistState(force: true)
        logger.info("engine", "start(): tracking enabled")
        events.emit(.enabledchange, ["enabled": true])
        beginTracking(reason: "start")
        requestMotionChange()
    }

    func stop(reason: String) {
        let wasEnabled = state.enabled
        state.enabled = false
        detector = StopDetector(isMoving: false)
        pendingMotion = nil
        syncDetectorState()
        persistState(force: true)
        endTracking()
        logger.info("engine", "stopped: \(reason)")
        if wasEnabled { events.emit(.enabledchange, ["enabled": false]) }
    }

    func changePace(_ isMoving: Bool) throws {
        guard state.enabled else { throw LongPingError(.notEnabled, "tracking is not enabled; call start() first") }
        let now = clock.nowMs
        // The point is the fix recorded as the motionchange right now, or none (StopDetector.changePace).
        let here = detector.changePace(isMoving, lastFix: lastFix, now: now, minAccuracyM: config.minAccuracyM)
        syncDetectorState()
        logger.info("motion", "changePace(\(isMoving)): now \(isMoving ? "moving" : "parked")")
        reconcileRegion()
        recordMotionChange(here, requestedAt: now)
    }

    // MARK: - Tracking session

    private func beginTracking(reason: String) {
        guard !trackingActive else {
            updateSampling()
            return
        }
        trackingActive = true
        trackingStartedAt = clock.nowMs
        location.startSignificantChanges()
        adoptOrClearExistingRegion()
        watchdogTimer.schedule(after: Watchdog.tickSec, repeating: Watchdog.tickSec) { [weak self] in self?.watchdogTick() }
        updateSampling()
        logger.info("engine", "tracking (\(reason)): \(detector.isMoving ? "moving" : "parked"), interval \(JSONValue.format(effectiveInterval)) s")
    }

    private func endTracking() {
        trackingActive = false
        watchdogTimer.cancel()
        samplingTimer.cancel()
        pendingMotion = nil
        location.stopSignificantChanges()
        location.removeParkedRegion()
        monitoredRegion = nil
        applyLocationPlan()
    }

    private var effectiveInterval: Double {
        IntervalPolicy.effectiveInterval(isMoving: detector.isMoving, config: config, battery: battery.snapshot)
    }

    private var parkedRegionRadius: Double { max(100, config.stopRadiusM * 2) }

    /// After a relaunch CoreLocation still monitors the region from the previous process. Keep it while
    /// parked (re-adding could swallow the exit event that woke us), drop it while moving.
    private func adoptOrClearExistingRegion() {
        if !detector.isMoving, let region = location.parkedRegion {
            monitoredRegion = (region.center.latitude, region.center.longitude, region.radius)
            reconcileRegion()
        } else {
            monitoredRegion = nil
            if detector.isMoving { location.removeParkedRegion() } else { reconcileRegion() }
        }
    }

    /// Parked with a known spot → exit-only region there; otherwise none.
    private func reconcileRegion() {
        guard trackingActive, !detector.isMoving, let parked = detector.parkedAt else {
            if monitoredRegion != nil || location.parkedRegion != nil {
                location.removeParkedRegion()
                monitoredRegion = nil
            }
            return
        }
        let radius = parkedRegionRadius
        if let current = monitoredRegion, abs(current.radius - radius) < 1,
           Geo.distance(current.latitude, current.longitude, parked.latitude, parked.longitude) < 1 {
            return
        }
        location.monitorParkedRegion(latitude: parked.latitude, longitude: parked.longitude, radius: radius)
        monitoredRegion = (parked.latitude, parked.longitude, radius)
    }

    /// The low-power-between-fixes scheme and its timer (intervals >= 60 s).
    private func updateSampling() {
        samplingTimer.cancel()
        if trackingActive {
            let now = clock.nowMs
            let plan = SamplingPlan.plan(now: now, intervalSec: effectiveInterval, lastRecordedTime: gate.lastRecordedTime,
                                         needsFixNow: pendingMotion != nil)
            if plan.mode != samplingMode {
                logger.debug("location", plan.mode == .lowPower ? "low power until the next fix is due" : "configured accuracy on")
            }
            samplingMode = plan.mode
            if let boostAt = plan.boostAt {
                samplingTimer.schedule(after: Double(boostAt - now) / 1000) { [weak self] in self?.updateSampling() }
            }
        } else {
            samplingMode = .configured
        }
        applyLocationPlan()
    }

    /// One place decides whether CoreLocation runs and how precisely: tracking plan + pending one-shot requests.
    private func applyLocationPlan() {
        guard trackingActive || !currentRequests.isEmpty else {
            location.stopUpdates()
            return
        }
        var accuracy = kCLLocationAccuracyThreeKilometers
        if trackingActive, samplingMode == .configured { accuracy = config.accuracy.clAccuracy }
        for request in currentRequests { accuracy = min(accuracy, request.accuracy.clAccuracy) }
        location.run(LocationController.Settings(
            desiredAccuracy: accuracy,
            activityType: config.ios.activityType.clActivityType,
            showsBackgroundIndicator: config.ios.showsBackgroundLocationIndicator
        ))
    }

    // MARK: - Fixes

    func locationController(_ controller: LocationController, didReceive locations: [CLLocation]) {
        let now = clock.nowMs
        var received = false
        for location in locations {
            guard let fix = Fix(location) else { continue }
            received = true
            if fix.time >= (lastFix?.time ?? .min) { lastFix = fix }
            offerToCurrentRequests(fix, now: now)
            if trackingActive { process(fix, now: now) }
        }
        if received {
            state.lastFixTime = now
            persistState(force: false)
        }
    }

    private func process(_ fix: Fix, now: EpochMs) {
        switch detector.process(fix, settings: StopDetector.Settings(config)) {
        case .parked(let at):
            pendingMotion = nil
            syncDetectorState()
            logger.info("motion", "parked: within \(JSONValue.format(config.stopRadiusM)) m for \(JSONValue.format(config.stopTimeoutSec)) s")
            reconcileRegion()
            record(at, event: .motionchange)
        case .moved(let at):
            pendingMotion = nil
            syncDetectorState()
            logger.info("motion", "moving: left the parked spot")
            reconcileRegion()
            record(at, event: .motionchange)
        case .none:
            syncDetectorState()
            if !detector.isMoving { reconcileRegion() }
            if var pending = pendingMotion {
                if let chosen = pending.offer(fix, now: now, minAccuracyM: config.minAccuracyM) {
                    pendingMotion = nil
                    record(chosen, event: .motionchange)
                } else {
                    pendingMotion = pending
                }
                return
            }
            switch gate.evaluate(fix, now: now, intervalSec: effectiveInterval, minAccuracyM: config.minAccuracyM) {
            case .record(let chosen, let waived):
                if waived {
                    logger.info("location", "no fix within \(JSONValue.format(config.minAccuracyM)) m for interval + 30 s: recording the best one (±\(meters(chosen.accuracy)) m)")
                }
                record(chosen, event: .interval)
            case .inaccurate:
                inaccurateSinceRecord += 1
                logger.debug("location", "fix rejected: ±\(meters(fix.accuracy)) m > minAccuracyM \(JSONValue.format(config.minAccuracyM))")
            case .tooSoon, .stale:
                break
            }
        }
    }

    /// Motion change now if a fresh accurate fix is known, else when the next one arrives.
    private func requestMotionChange() {
        let now = clock.nowMs
        recordMotionChange(PendingMotionChange.immediateFix(lastFix: lastFix, now: now, minAccuracyM: config.minAccuracyM),
                           requestedAt: now)
    }

    /// Records `fix` as the motion change now, or (nil) waits for the next fix.
    private func recordMotionChange(_ fix: Fix?, requestedAt now: EpochMs) {
        if let fix {
            pendingMotion = nil
            record(fix, event: .motionchange)
        } else {
            pendingMotion = PendingMotionChange(isMoving: detector.isMoving, requestedAt: now)
            updateSampling()
        }
    }

    private func record(_ fix: Fix, event: RecordEvent) {
        let record = LocationRecord(fix: fix, event: event, isMoving: detector.isMoving, battery: battery.snapshot,
                                    extras: config.http.extras)
        gate.markRecorded(fix.time)
        if inaccurateSinceRecord > 0 {
            logger.debug("location", "\(inaccurateSinceRecord) inaccurate fix(es) skipped before this record")
            inaccurateSinceRecord = 0
        }
        persist(record)
        if event == .motionchange {
            events.emit(.motionchange, ["isMoving": detector.isMoving, "location": record.json.dictionaryObject])
        }
        syncDetectorState()
        // Interval records at 1 s would rewrite UserDefaults every second; the throttle loses at most
        // a few seconds of `lastRecordedTime` on a kill, which only makes the next record come early.
        persistState(force: event != .interval)
        updateSampling()
    }

    /// Store, queue for upload and emit `location`.
    private func persist(_ record: LocationRecord) {
        state.lastLocation = record.json
        logger.debug("location", "recorded \(record.event.rawValue) ±\(meters(record.fix.accuracy)) m")
        store.enqueue(record, persistence: config.persistence, now: clock.nowMs) { [logger, uploader] result in
            switch result {
            case .success(let pruned):
                if pruned.total > 0 {
                    logger.info("queue", "pruned \(pruned.overLimit) record(s) over maxRecords and \(pruned.expired) older than maxDays")
                }
                uploader.trigger(.recordInserted)
            case .failure(let error):
                logger.error("queue", "record \(record.uuid) not stored: \(error)")
            }
        }
        events.emit(.location, record.json.dictionaryObject)
    }

    private func syncDetectorState() {
        state.isMoving = state.enabled && detector.isMoving
        state.anchor = detector.anchor
        state.parkedAt = detector.parkedAt
        state.lastRecordedTime = gate.lastRecordedTime
    }

    private func persistState(force: Bool) {
        let now = clock.nowMs
        guard force || now - lastStatePersistAt >= Self.statePersistIntervalMs else { return }
        lastStatePersistAt = now
        preferences.save(state)
    }

    // MARK: - Watchdog

    private func watchdogTick() {
        let now = clock.nowMs
        guard state.enabled else { return watchdogTimer.cancel() }
        if trackingActive {
            let reference = max(state.lastFixTime ?? trackingStartedAt, trackingStartedAt, lastRestartAt)
            if Watchdog.isStalled(now: now, lastFixTime: reference, intervalSec: effectiveInterval) {
                lastRestartAt = now
                logger.warn("watchdog", "no fix for \((now - reference) / 1000) s: restarting location updates")
                location.restartUpdates()
            }
            if let pending = pendingMotion, let chosen = pending.takeExpired(now: now) {
                pendingMotion = nil
                logger.info("motion", "no accurate fix for the motion change within 30 s: recording the best one")
                record(chosen, event: .motionchange)
            } else if pendingMotion == nil, let overdue = gate.takeOverdue(now: now, intervalSec: effectiveInterval) {
                logger.info("location", "interval overdue with only inaccurate fixes: recording the best one (±\(meters(overdue.accuracy)) m)")
                record(overdue, event: .interval)
            }
        }
        uploader.trigger(.watchdog)
        if now - lastLogPruneAt >= Self.logPruneIntervalMs {
            lastLogPruneAt = now
            store.pruneLog(olderThan: now - EpochMs(config.logMaxDays) * .dayMs) { [logger] deleted in
                if deleted > 0 { logger.debug("storage", "pruned \(deleted) log line(s)") }
            }
        }
        persistState(force: false)
    }

    // MARK: - Battery, authorization, errors, region

    private func batteryChanged(_ snapshot: BatterySnapshot) {
        guard config.lowBattery != nil, trackingActive else { return }
        logger.debug("battery", "level \(meters(snapshot.level * 100))%, charging \(snapshot.isCharging)")
        updateSampling()
    }

    func locationControllerDidChangeAuthorization(_ controller: LocationController) {
        let status = controller.authorizationStatus
        let full = controller.isFullAccuracy
        permissions.authorizationDidChange(status)
        let changed = status != lastAuthorization || full != lastFullAccuracy
        let firstReport = lastAuthorization == nil
        lastAuthorization = status
        lastFullAccuracy = full
        // Also called when Location Services are switched on/off without a status change, so every
        // callback after the initial one is reported.
        if !firstReport { emitProviderChange() }
        guard changed else { return }
        logger.info("permission", "authorization \(status.name), accuracy \(full ? "full" : "reduced")")
        if !full, state.enabled {
            logger.warn("permission", "precise location is off: fixes are approximate (several km)")
        }
        if status.isAuthorized {
            if state.enabled, !trackingActive { beginTracking(reason: "permission granted") }
        } else if status != .notDetermined {
            failCurrentRequests(LongPingError(.permissionDenied, "location permission is \(status.name)"))
            if state.enabled {
                logger.error("permission", "location permission is \(status.name): no fixes until it is granted again")
                events.emit(.error, ["code": ErrorCode.permissionDenied.rawValue, "message": "location permission is \(status.name)"])
            }
        }
    }

    func locationController(_ controller: LocationController, didFail error: Error) {
        let clError = error as? CLError
        switch clError?.code {
        case .locationUnknown?:
            logger.debug("location", "location temporarily unknown")
        case .denied?:
            logger.error("location", "CoreLocation denied access")
            if state.enabled {
                events.emit(.error, ["code": ErrorCode.permissionDenied.rawValue, "message": "location access denied"])
            }
        default:
            logger.warn("location", "location error: \(error.localizedDescription)")
            if state.enabled {
                events.emit(.error, ["code": ErrorCode.internalError.rawValue, "message": error.localizedDescription])
            }
        }
    }

    func locationControllerDidExitParkedRegion(_ controller: LocationController) {
        guard state.enabled, !detector.isMoving else { return }
        logger.info("motion", "left the parked region: moving")
        detector.forceMoving(at: nil)
        syncDetectorState()
        if !trackingActive, location.authorizationStatus.isAuthorized {
            beginTracking(reason: "region exit")
        }
        reconcileRegion()
        requestMotionChange()
    }

    // MARK: - getCurrentPosition

    final class CurrentPositionRequest {
        let accuracy: Accuracy
        let startedAt: EpochMs
        let options: CurrentPositionOptions
        let completion: (Result<[String: Any], LongPingError>) -> Void
        let timer = EngineTimer(queue: .main)
        var best: Fix?

        init(accuracy: Accuracy, startedAt: EpochMs, options: CurrentPositionOptions,
             completion: @escaping (Result<[String: Any], LongPingError>) -> Void) {
            self.accuracy = accuracy
            self.startedAt = startedAt
            self.options = options
            self.completion = completion
        }

        func accepts(_ fix: Fix) -> Bool {
            CurrentPositionPolicy.accepts(fix, startedAt: startedAt, maximumAgeSec: options.maximumAgeSec)
        }
    }

    func getCurrentPosition(_ options: CurrentPositionOptions,
                            completion: @escaping (Result<[String: Any], LongPingError>) -> Void) {
        let status = location.authorizationStatus
        guard status.isAuthorized else {
            return completion(.failure(LongPingError(.permissionDenied, "location permission is \(status.name)")))
        }
        Self.checkServicesEnabled { [weak self] enabled in
            guard let self else { return }
            guard enabled else {
                return completion(.failure(LongPingError(.locationServicesOff, "Location Services are turned off")))
            }
            let now = self.clock.nowMs
            let request = CurrentPositionRequest(accuracy: options.accuracy ?? self.config.accuracy, startedAt: now,
                                                 options: options, completion: completion)
            if let cached = CurrentPositionPolicy.cachedFix(self.freshestKnownFix(), now: now,
                                                            maximumAgeSec: options.maximumAgeSec) {
                return self.complete(request, with: cached)
            }
            self.currentRequests.append(request)
            request.timer.schedule(after: options.timeoutSec) { [weak self, weak request] in
                guard let self, let request else { return }
                self.timeOut(request)
            }
            self.applyLocationPlan()
        }
    }

    private func offerToCurrentRequests(_ fix: Fix, now: EpochMs) {
        for request in currentRequests where request.accepts(fix) {
            if fix.accuracy < (request.best?.accuracy ?? .infinity) { request.best = fix }
            if fix.accuracy <= CurrentPositionPolicy.targetAccuracyM(request.accuracy) { complete(request, with: fix) }
        }
    }

    private func timeOut(_ request: CurrentPositionRequest) {
        guard currentRequests.contains(where: { $0 === request }) else { return }
        let now = clock.nowMs
        if let fix = CurrentPositionPolicy.onTimeout(best: request.best, lastKnown: freshestKnownFix(), now: now) {
            let source = request.best == nil ? "the last known fix (\((now - fix.time) / 1000) s old)" : "the best fix seen"
            logger.info("location", "getCurrentPosition timed out: returning \(source), ±\(meters(fix.accuracy)) m")
            return complete(request, with: fix)
        }
        remove(request)
        logger.warn("location", "getCurrentPosition timed out without a fix")
        request.completion(.failure(LongPingError(.timeout, "no location within \(JSONValue.format(request.options.timeoutSec)) s")))
    }

    private func complete(_ request: CurrentPositionRequest, with fix: Fix) {
        remove(request)
        let record = LocationRecord(fix: fix, event: .current, isMoving: state.enabled && detector.isMoving,
                                    battery: battery.snapshot, extras: config.http.extras.merging(request.options.extras))
        if request.options.persist {
            persist(record)
            persistState(force: true)
        }
        request.completion(.success(record.json.dictionaryObject))
    }

    private func remove(_ request: CurrentPositionRequest) {
        request.timer.cancel()
        let before = currentRequests.count
        currentRequests.removeAll { $0 === request }
        if currentRequests.count != before { applyLocationPlan() }
    }

    private func failCurrentRequests(_ error: LongPingError) {
        let pending = currentRequests
        pending.forEach { remove($0) }
        pending.forEach { $0.completion(.failure(error)) }
    }

    private func freshestKnownFix() -> Fix? {
        CurrentPositionPolicy.freshest([lastFix, location.lastKnownLocation.flatMap(Fix.init)])
    }

    // MARK: - Permission, settings, state

    func requestPermission(_ level: PermissionFlow.Level, completion: @escaping (Int) -> Void) {
        permissions.request(level, completion: completion)
    }

    func setAuthorizationRequired(_ value: Bool) {
        guard state.authorizationRequired != value else { return }
        state.authorizationRequired = value
        persistState(force: true)
    }

    /// Server `long_ping` command from an upload response. `reset` clears the overrides, then `config` merges
    /// into them; only a change of the effective config is applied live and emitted as `configchange`.
    func applyRemote(_ command: RemoteCommand) {
        if command.config != nil || command.reset {
            let previous = config
            let change = layers.applyRemote(config: command.config, reset: command.reset)
            if command.reset { logger.info("config", "remote reset: server overrides cleared") }
            if change.ignored { logger.info("config", "remote config ignored (remoteConfig is false)") }
            if change.remoteConfigKeyIgnored { logger.warn("config", "remote config: remoteConfig ignored (only the app sets it)") }
            if let rejected = change.rejected { logger.error("config", "remote config rejected: \(rejected)") }
            log(change.notes)
            if change.overridesChanged { preferences.saveRemoteOverrides(layers.overrides) }
            if change.effectiveChanged {
                logger.level = config.logLevel
                logger.info("config", "remote config applied")
                uploader.update(http: config.http)
                applyLive(previous: previous)
                events.emit(.configchange, config.json.dictionaryObject)
            } else if command.config != nil, !change.ignored, change.rejected == nil {
                logger.debug("config", "remote config: no change")
            }
        }
        if command.stop, state.enabled {
            stop(reason: "server sent long_ping.stop")
        }
    }

    /// State without queueCount (filled in from the io queue by the caller).
    func stateDictionary(queueCount: Int) -> [String: Any] {
        [
            "enabled": state.enabled,
            "isMoving": state.enabled && detector.isMoving,
            "lastLocation": state.lastLocation?.foundationObject ?? NSNull(),
            "lastLocationAt": state.lastLocationAt.map { NSNumber(value: Double($0)) } ?? NSNull(),
            "queueCount": queueCount,
            "authorizationRequired": state.authorizationRequired,
            "config": config.json.dictionaryObject,
        ]
    }

    func providerState(_ completion: @escaping ([String: Any]) -> Void) {
        Self.checkServicesEnabled { [weak self] enabled in
            guard let self else { return }
            completion([
                "enabled": enabled,
                "gps": enabled,
                "network": enabled,
                "status": self.location.authorizationStatus.contractValue,
                "accuracyAuthorization": self.location.isFullAccuracy ? "full" : "reduced",
                "powerSaveMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "ignoringBatteryOptimizations": true,
            ])
        }
    }

    private func emitProviderChange() {
        providerState { [events] in events.emit(.providerchange, $0) }
    }

    /// `locationServicesEnabled()` can block, and Xcode flags it on the main thread; ask on a background
    /// queue and continue on main.
    static func checkServicesEnabled(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let enabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async { completion(enabled) }
        }
    }
}

extension JSONValue {
    /// Objects as `[String: Any]` for events and promise results; anything else as an empty dictionary.
    var dictionaryObject: [String: Any] { foundationObject as? [String: Any] ?? [:] }
}
