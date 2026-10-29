package com.longping.engine

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.longping.core.AuthCredentials
import com.longping.core.BatteryState
import com.longping.core.Clock
import com.longping.core.ConfigException
import com.longping.core.ConfigLayers
import com.longping.core.ConfigResolver
import com.longping.core.CurrentPositionOptions
import com.longping.core.EngineState
import com.longping.core.ErrorCode
import com.longping.core.Fix
import com.longping.core.Intervals
import com.longping.core.Iso8601
import com.longping.core.LocationRecord
import com.longping.core.LocationRequestSpec
import com.longping.core.LogQuery
import com.longping.core.LongPingConfig
import com.longping.core.LongPingException
import com.longping.core.MotionTransition
import com.longping.core.NotificationText
import com.longping.core.RecordEvent
import com.longping.core.RecordingGate
import com.longping.core.RemoteDirective
import com.longping.core.StopDetector
import com.longping.core.StopParams
import com.longping.core.UploadTrigger
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Receives events for JS. The React Native module implements it while it is alive. */
interface EventSink {
    fun emit(name: String, payload: JSONObject)
}

/**
 * Process-wide engine (DESIGN.md, "Lifecycle and recovery -> Android"). Works with no React
 * instance: the boot receiver, the WorkManager watchdog and the service all reach it through
 * [get]. Every piece of mutable state is owned by one HandlerThread; public calls post to it.
 */
class LongPingEngine private constructor(context: Context) {
    companion object {
        private const val TAG = "engine"
        private const val WATCHDOG_MS = 60_000L
        private const val DUE_FIX_MIN_DELAY_MS = 1_000L
        private const val STATE_PERSIST_EVERY_MS = 30_000L
        private const val PRUNE_EVERY_TICKS = 60
        private const val DAY_MS = 86_400_000L
        private const val SERVICE_START_PENDING_MS = 15_000L
        private const val AVAILABILITY_GRACE_MS = 10_000L

        // Holds only the application context, which lives as long as the process.
        @SuppressLint("StaticFieldLeak")
        @Volatile
        private var instance: LongPingEngine? = null

        @JvmStatic
        fun get(context: Context): LongPingEngine =
            instance ?: synchronized(this) { instance ?: LongPingEngine(context.applicationContext ?: context).also { instance = it } }
    }

    private val app: Context = context
    private val clock = Clock { System.currentTimeMillis() }
    private val thread = HandlerThread("LongPing").apply { start() }
    internal val handler = Handler(thread.looper)
    internal val looper: Looper get() = thread.looper

    private val prefs = EnginePrefs(app)
    private val db = LongPingDatabase(app)
    private val queue = QueueStore(db)
    private val log = Logger(LogStore(db), clock)
    private val auth = AuthStore(prefs, log)
    internal val permissions = Permissions(app, prefs)
    internal val deviceSettings = DeviceSettings(app)
    internal val notifications = TrackingNotification(app)
    private val battery = BatteryMonitor(app)
    private val providers = ProviderMonitor(app, permissions, deviceSettings) { guard("provider change") { onProviderChange(it) } }
    private val network = NetworkMonitor(app, log) { uploader.trigger(UploadTrigger.CONNECTIVITY) }
    private val uploader: Uploader

    /** The app's config and the server's overrides; [config] is the effective result. Engine thread only. */
    private val layers: ConfigLayers
    private val overridesDroppedAtLaunch: ConfigException?

    init {
        val restored = ConfigLayers.restore(ConfigResolver.restore(prefs.config), prefs.remoteOverrides)
        layers = restored.layers
        overridesDroppedAtLaunch = restored.droppedOverrides
    }

    @Volatile
    internal var config: LongPingConfig = layers.effective
        private set

    @Volatile
    private var state: EngineState = EngineState.fromJson(prefs.state)
    private val detector = StopDetector(state.motion)
    private val gate = RecordingGate(state.lastRecordedTimeMs)

    private var lastFix: Fix? = null
    private var lastLocation: JSONObject? = prefs.lastLocation?.let { runCatching { JSONObject(it) }.getOrNull() }
    private var lastLocationAt: Long? = prefs.lastLocationAt
    private var service: LongPingService? = null
    private var batteryState = BatteryState.UNKNOWN
    private var activeSpec: LocationRequestSpec? = null
    private var updatesRequestedAt = 0L
    private var lastStatePersistAt = 0L
    private var stateDirty = false
    private var lastLocationDirty = false
    private var lastNotificationAt = 0L
    private var locationAvailable: Boolean? = null
    private var unavailableSinceMs = 0L
    private var unavailabilityLogged = false
    private var serviceRequestedAt = 0L
    private var watchdogTicks = 0

    @Volatile
    private var queueCountCache = 0L

    @Volatile
    private var sink: EventSink? = null

    private val watchdog = object : Runnable {
        override fun run() {
            try {
                tick()
            } catch (e: Exception) {
                log.error(TAG, "watchdog tick failed", e)
            }
            if (service != null) handler.postDelayed(this, WATCHDOG_MS)
        }
    }

    /**
     * Android delivers fixes on the fused provider's own clock, about once per interval and often a little
     * early, or early by a lot when another request on the device woke it. A fix skipped as too soon then
     * left the next one a whole interval away (60 s became 120 s, 180 s became 5 min on a Galaxy S22), so a
     * skip asks for one fresh fix at the moment the interval is due. Any record cancels it.
     */
    private val dueFix = Runnable { service?.requestImmediateFix(config.accuracy) }

    private fun scheduleDueFix() {
        val wait = Intervals.msUntilDue(gate.lastRecordedTimeMs, currentIntervalMs(), clock.nowMs()) ?: return
        handler.removeCallbacks(dueFix)
        // At least DUE_FIX_MIN_DELAY_MS: a fix fetched right at the due time can carry a timestamp a
        // moment before it, and must not turn into back-to-back requests.
        handler.postDelayed(dueFix, maxOf(wait, DUE_FIX_MIN_DELAY_MS))
    }

    /** Posted when the fused provider reports "unavailable"; cancelled if it recovers within the grace. */
    private val availabilityLost = Runnable {
        if (locationAvailable == false && service != null) {
            unavailabilityLogged = true
            log.warn(TAG, "location unavailable for ${(clock.nowMs() - unavailableSinceMs) / 1000} s (no provider can produce a fix right now)")
        }
    }

    init {
        log.level = config.logLevel
        uploader = Uploader(app, queue, auth, prefs, log, clock, object : Uploader.Host {
            override val config: LongPingConfig get() = this@LongPingEngine.config
            override fun emit(event: String, payload: JSONObject) = this@LongPingEngine.emit(event, payload)
            override fun onRemoteDirective(directive: RemoteDirective) = post("server directive") { applyRemote(directive) }
        })
        post("engine init") {
            log.info(TAG, "engine started (enabled=${state.enabled}, queued=${countQueue()})")
            overridesDroppedAtLaunch?.let {
                prefs.saveRemoteOverrides(layers.overridesJson)
                log.error(TAG, "server overrides cleared: they do not validate with the stored config (${it.message})")
            }
            seedRecordingClock()
            network.start()
            providers.start(handler)
            pruneStorage()
            if (state.enabled || queueCountCache > 0) WatchdogWork.ensureScheduled(app, log)
        }
    }

    // ---------------------------------------------------------------- bridge API (any thread)

    internal fun attachSink(s: EventSink) {
        sink = s
    }

    internal fun detachSink(s: EventSink) {
        if (sink === s) sink = null
    }

    internal fun configure(input: JSONObject, cb: (Result<JSONObject>) -> Unit) = exec(cb) {
        applyLocalConfig(input, merge = false, source = "configure")
        stateJson()
    }

    internal fun setConfig(partial: JSONObject, cb: (Result<JSONObject>) -> Unit) = exec(cb) {
        applyLocalConfig(partial, merge = true, source = "setConfig")
        stateJson()
    }

    internal fun start(cb: (Result<JSONObject>) -> Unit) = exec(cb) {
        startTracking()
        stateJson()
    }

    internal fun stop(cb: (Result<JSONObject>) -> Unit) = exec(cb) {
        stopTracking("stop()")
        stateJson()
    }

    internal fun getState(cb: (Result<JSONObject>) -> Unit) = exec(cb) { stateJson() }

    internal fun setAuthorization(input: JSONObject, cb: (Result<Unit>) -> Unit) = exec(cb) {
        auth.set(AuthCredentials.fromJson(input))
        log.info(TAG, "authorization stored")
        uploader.authorizationChanged()
    }

    internal fun clearAuthorization(cb: (Result<Unit>) -> Unit) = exec(cb) {
        auth.clear()
        log.info(TAG, "authorization cleared")
    }

    internal fun changePace(isMoving: Boolean, cb: (Result<JSONObject>) -> Unit) = exec(cb) {
        if (!state.enabled) throw LongPingException(ErrorCode.NOT_ENABLED, "tracking is stopped; call start() first")
        val now = clock.nowMs()
        // Only a fresh, accurate fix may stand for "here, now"; see RecordingGate.forcedMotionFix.
        val here = RecordingGate.forcedMotionFix(lastFix, now, config.minAccuracyM)
        detector.force(isMoving, here?.toPoint())
        state = state.withMotion(detector.state)
        persistState(durable = false, force = true)
        log.info(TAG, "changePace: now ${motionWord(isMoving)}")
        reevaluateRequest("changePace")
        if (here != null) {
            onRecordDecision(gate.recordMotionChange(here))
        } else {
            gate.requestMotionChange(now)
            service?.requestImmediateFix(config.accuracy)
        }
        stateJson()
    }

    internal fun getCurrentPosition(input: JSONObject, cb: (Result<JSONObject>) -> Unit) {
        post("getCurrentPosition") {
            try {
                val options = CurrentPositionOptions.parse(input, config.accuracy)
                requireLocationAccess()
                CurrentPositionRequest(app, handler, clock, options, config.minAccuracyM, lastFix) { result ->
                    cb(result.mapCatching { fix -> currentPositionRecord(fix, options) })
                }.start()
            } catch (e: Exception) {
                cb(Result.failure(asLongPing(e)))
            }
        }
    }

    internal fun sync(cb: (Result<Int>) -> Unit) = uploader.trigger(UploadTrigger.SYNC) { cb(Result.success(it)) }

    internal fun getQueueCount(cb: (Result<Long>) -> Unit) = exec(cb) { countQueue() }

    internal fun clearQueue(cb: (Result<Unit>) -> Unit) = exec(cb) {
        log.info(TAG, "queue cleared (${queue.clear()} records)")
        queueCountCache = 0
    }

    internal fun getProviderState(activity: Activity?, cb: (Result<JSONObject>) -> Unit) = exec(cb) { providers.read(activity) }

    internal fun getLog(options: JSONObject, cb: (Result<String>) -> Unit) {
        val q = try {
            LogQuery.parse(options, clock.nowMs())
        } catch (e: Exception) {
            cb(Result.failure(asLongPing(e)))
            return
        }
        log.query(q, cb)
    }

    internal fun clearLog(cb: (Result<Unit>) -> Unit) = log.clear(cb)

    /**
     * App launch / app back in the foreground: restart tracking if it should be running. The app
     * being opened also lifts a boot-time suppression (enabled but startOnBoot = false).
     */
    internal fun resumeIfEnabled(reason: String, activity: Activity? = null) {
        post("resume") {
            prefs.bootSuppressed = false
            providers.check(activity)
            resume(reason)
        }
    }

    internal fun onPermissionResult(status: Int) {
        post("permission result") {
            log.info(TAG, "permission request finished: status $status")
            providers.check(null)
            resume("permission granted")
        }
    }

    // ---------------------------------------------------------------- OS entry points

    internal fun onBoot(kind: String, done: () -> Unit) {
        post(kind) {
            try {
                log.info(TAG, "$kind (enabled=${state.enabled}, startOnBoot=${config.startOnBoot})")
                // Remembered so the WorkManager watchdog does not restart what startOnBoot = false left off.
                prefs.bootSuppressed = state.enabled && !config.startOnBoot
                resume(kind)
                if (countQueue() > 0) {
                    WatchdogWork.ensureScheduled(app, log)
                    uploader.trigger(UploadTrigger.WATCHDOG)
                }
            } finally {
                done()
            }
        }
    }

    /** WorkManager tick (worker thread, blocking): resume, drain uploads, cancel the work once it has nothing to guard. */
    internal fun onWatchdogWork() {
        val latch = CountDownLatch(1)
        post("watchdog work") {
            try {
                log.debug(TAG, "watchdog work (service ${if (service != null) "running" else "not running"})")
                resume("watchdog work")
            } finally {
                latch.countDown()
            }
        }
        latch.await(10, TimeUnit.SECONDS)
        uploader.runBlocking(UploadTrigger.WATCHDOG, 5 * 60_000L)
        // On the engine thread, so it cannot race start()'s ensureScheduled().
        post("watchdog work cleanup") {
            if (!state.enabled && countQueue() == 0L) {
                log.debug(TAG, "watchdog work no longer needed")
                WatchdogWork.cancel(app)
            }
        }
    }

    internal fun currentNotification(): Notification = notifications.build(config, notificationText())

    internal fun onServiceStarted(svc: LongPingService, restartedBySystem: Boolean) {
        post("service start") {
            serviceRequestedAt = 0L
            if (!state.enabled || !mayTrack("service start")) {
                log.info(TAG, "service started while tracking is off; stopping it")
                if (service === svc) service = null
                svc.shutdown()
                return@post
            }
            if (restartedBySystem) log.warn(TAG, "service restarted by the system after its process was killed")
            if (service !== svc) {
                service = svc
                batteryState = battery.current()
                battery.start(handler) { guard("battery change") { onBatteryChanged(it) } }
                activeSpec = null
                resetAvailability()
                gate.beginWindow(clock.nowMs())
                handler.removeCallbacks(watchdog)
                handler.postDelayed(watchdog, WATCHDOG_MS)
                log.info(TAG, "location service running")
            }
            reevaluateRequest("service start")
            if (gate.isMotionChangePending) svc.requestImmediateFix(config.accuracy)
            refreshNotification(force = true)
        }
    }

    internal fun onServiceDestroyed(svc: LongPingService) {
        post("service destroyed") {
            if (service !== svc) return@post
            service = null
            activeSpec = null
            battery.stop()
            handler.removeCallbacks(watchdog)
            resetAvailability()
            if (state.enabled) {
                log.warn(TAG, "location service destroyed while tracking is enabled; the watchdog will restart it")
                WatchdogWork.ensureScheduled(app, log)
            } else {
                log.info(TAG, "location service stopped")
            }
        }
    }

    internal fun onServiceStartFailed(e: Throwable) {
        post("service start failure") {
            serviceRequestedAt = 0L
            val code = if (e is SecurityException) ErrorCode.PERMISSION_DENIED else ErrorCode.INTERNAL
            emitError(code, "location service could not enter the foreground: ${e.javaClass.simpleName}: ${e.message}")
            if (state.enabled) WatchdogWork.ensureScheduled(app, log)
        }
    }

    internal fun onTaskRemoved() {
        post("task removed") {
            if (config.stopOnTerminate && state.enabled) {
                stopTracking("app removed from recents with stopOnTerminate")
            } else {
                log.info(TAG, "app removed from recents; tracking continues")
            }
        }
    }

    internal fun onLocationRequestFailed(e: Exception) {
        post("location request failure") {
            val code = if (e is SecurityException) ErrorCode.PERMISSION_DENIED else ErrorCode.INTERNAL
            emitError(code, "location request failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * Called on the engine looper by the fused callback. The fused provider can report
     * "unavailable" for a few milliseconds around every delivery (seen on every fix in the Android
     * e2e run), so only an outage that lasts longer than [availabilityGraceMs] is logged; the
     * matching "available again" line is written only after such a warning.
     */
    internal fun onLocationAvailability(available: Boolean) {
        if (locationAvailable == available) return
        locationAvailable = available
        handler.removeCallbacks(availabilityLost)
        if (!available) {
            unavailableSinceMs = clock.nowMs()
            handler.postDelayed(availabilityLost, availabilityGraceMs())
        } else if (unavailabilityLogged) {
            unavailabilityLogged = false
            log.info(TAG, "location available again after ${(clock.nowMs() - unavailableSinceMs) / 1000} s")
        }
    }

    private fun availabilityGraceMs() = maxOf(AVAILABILITY_GRACE_MS, currentIntervalMs())

    private fun resetAvailability() {
        handler.removeCallbacks(availabilityLost)
        locationAvailable = null
        unavailabilityLogged = false
    }

    /** Called on the engine looper with fixes from the continuous request or an immediate fix. */
    internal fun onLocations(locations: List<Location>) {
        if (!state.enabled || service == null) return
        for (l in locations.sortedBy { it.time }) {
            try {
                onFix(LocationMapper.toFix(l))
            } catch (e: Exception) {
                log.error(TAG, "fix processing failed", e)
            }
        }
    }

    // ---------------------------------------------------------------- tracking

    private fun startTracking() {
        requireLocationAccess()
        if (state.enabled && service != null) {
            log.info(TAG, "start(): already tracking")
            return
        }
        val wasEnabled = state.enabled
        val now = clock.nowMs()
        prefs.bootSuppressed = false
        detector.force(true, null)
        state = state.copy(enabled = true).withMotion(detector.state)
        persistState(durable = true)
        gate.beginWindow(now)
        gate.requestMotionChange(now)
        log.info(TAG, "tracking started")
        WatchdogWork.ensureScheduled(app, log)
        startService("start()")
        if (!wasEnabled) emit("enabledchange", JSONObject().put("enabled", true))
    }

    private fun stopTracking(reason: String) {
        val wasEnabled = state.enabled
        gate.cancelMotionChange()
        detector.force(false, null)
        state = state.copy(enabled = false).withMotion(detector.state)
        prefs.bootSuppressed = false
        persistState(durable = true)
        stopService()
        log.info(TAG, "tracking stopped ($reason)")
        if (wasEnabled) emit("enabledchange", JSONObject().put("enabled", false))
    }

    private fun resume(reason: String) {
        if (!state.enabled) return
        if (prefs.bootSuppressed) {
            log.info(TAG, "not resuming ($reason): startOnBoot is false; tracking resumes when the app is opened")
            return
        }
        WatchdogWork.ensureScheduled(app, log)
        if (service != null || !mayTrack(reason)) return
        startService(reason)
    }

    /** Permission gate for (re)starting; reports why not. */
    private fun mayTrack(reason: String): Boolean {
        if (!permissions.hasForeground()) {
            emitError(ErrorCode.PERMISSION_DENIED, "tracking not running ($reason): location permission is not granted")
            return false
        }
        return true
    }

    private fun requireLocationAccess() {
        if (!permissions.hasForeground()) {
            throw LongPingException(ErrorCode.PERMISSION_DENIED, "location permission not granted; call requestPermission() first")
        }
        if (!providers.isLocationEnabled()) throw LongPingException(ErrorCode.LOCATION_SERVICES_OFF, "location services are switched off")
    }

    private fun startService(reason: String) {
        val now = clock.nowMs()
        // Launch alone resumes twice (module init + onHostResume); one pending start is enough.
        if (now - serviceRequestedAt < SERVICE_START_PENDING_MS) {
            log.debug(TAG, "location service start already pending ($reason)")
            return
        }
        // From the background, a location FGS needs background permission (Android 11+ gives a
        // background-started service no while-in-use access; Android 14+ throws in startForeground,
        // which would then crash the app as "did not call startForeground"). Skip it and say why.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !permissions.hasBackground() && !AppVisibility.isVisible()) {
            emitError(
                ErrorCode.PERMISSION_DENIED,
                "cannot resume tracking from the background ($reason) without 'always' location permission; it resumes when the app is opened",
            )
            return
        }
        try {
            ContextCompat.startForegroundService(app, Intent(app, LongPingService::class.java))
            serviceRequestedAt = now
            log.info(TAG, "starting location service ($reason)")
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException (Android 12+, background without an exemption),
            // SecurityException, IllegalStateException: never crash the host app; WorkManager retries.
            emitError(ErrorCode.INTERNAL, "could not start the location service ($reason): ${e.javaClass.simpleName}: ${e.message}")
            WatchdogWork.ensureScheduled(app, log)
        }
    }

    /**
     * Only through the attached instance: stopping a service that was started with
     * startForegroundService() before it reached startForeground() crashes the app. A service
     * still starting sees enabled=false in onServiceStarted and stops itself.
     */
    private fun stopService() {
        val svc = service ?: return
        service = null
        activeSpec = null
        battery.stop()
        handler.removeCallbacks(watchdog)
        handler.removeCallbacks(dueFix)
        resetAvailability()
        svc.shutdown()
    }

    private fun onFix(fix: Fix) {
        val now = clock.nowMs()
        lastFix = fix
        state = state.copy(lastFixTimeMs = now)

        val transition = detector.evaluate(fix, StopParams.from(config))
        state = state.withMotion(detector.state) // anchor / parkedAt move without a transition too
        if (transition != null) {
            log.info(TAG, "now ${motionWord(transition == MotionTransition.MOVED)} (${describe(fix)})")
        }

        val decision = gate.offer(fix, now, currentIntervalMs(), config.minAccuracyM, motionChanged = transition != null)
        when (decision) {
            is RecordingGate.Decision.Record -> onRecordDecision(decision)
            is RecordingGate.Decision.Skip -> when (decision.reason) {
                RecordingGate.SkipReason.INACCURATE ->
                    log.info(TAG, "fix rejected: ±${fmt(fix.accuracy)} m is worse than minAccuracyM ${fmt(config.minAccuracyM)} m")
                RecordingGate.SkipReason.TOO_SOON -> {
                    log.debug(TAG, "fix skipped: interval not reached")
                    scheduleDueFix()
                }
            }
        }

        persistState(durable = false, force = transition != null)
        reevaluateRequest(if (transition != null) "motion change" else "fix")
        refreshNotification(force = false)
    }

    private fun onRecordDecision(d: RecordingGate.Decision.Record) {
        if (d.accuracyWaived) log.info(TAG, "accuracy filter waived for ${d.event.wire} fix ±${fmt(d.fix.accuracy)} m (no accurate fix in time)")
        record(d.fix, d.event, null)
        state = state.copy(lastRecordedTimeMs = gate.lastRecordedTimeMs)
        persistState(durable = false, force = d.event == RecordEvent.MOTIONCHANGE)
    }

    /** Stores, emits and queues one record. */
    private fun record(fix: Fix, event: RecordEvent, callExtras: JSONObject?): JSONObject {
        handler.removeCallbacks(dueFix)
        val uuid = UUID.randomUUID().toString()
        val json = LocationRecord.build(uuid, fix, event, state.isMoving, battery.current(), LocationRecord.mergeExtras(config.http.extras(), callExtras))
        try {
            queue.insert(uuid, fix.timeMs, json.toString())
            val pruned = queue.prune(config.persistence.maxRecords, clock.nowMs() - config.persistence.maxDays * DAY_MS)
            if (pruned.total > 0) {
                log.warn(TAG, "queue pruned: ${pruned.overLimit} over maxRecords, ${pruned.expired} older than maxDays")
            }
            queueCountCache = queue.count()
        } catch (e: Exception) {
            emitError(ErrorCode.INTERNAL, "could not store a location: ${e.javaClass.simpleName}: ${e.message}")
        }
        lastLocation = json
        lastLocationAt = fix.timeMs
        lastLocationDirty = true
        log.info(TAG, "recorded ${event.wire} (${describe(fix)}, ${motionWord(state.isMoving)})")
        if (!state.enabled) WatchdogWork.ensureScheduled(app, log) // uploads must still drain after process death
        emit("location", json)
        if (event == RecordEvent.MOTIONCHANGE) emit("motionchange", JSONObject().put("isMoving", state.isMoving).put("location", json))
        uploader.trigger(UploadTrigger.RECORD)
        return json
    }

    private fun currentPositionRecord(fix: Fix, options: CurrentPositionOptions): JSONObject {
        if (options.persist) return record(fix, RecordEvent.CURRENT, options.extras)
        val extras = LocationRecord.mergeExtras(config.http.extras(), options.extras)
        return LocationRecord.build(UUID.randomUUID().toString(), fix, RecordEvent.CURRENT, state.isMoving, battery.current(), extras)
    }

    private fun currentIntervalMs() = Intervals.effectiveIntervalMs(config, state.isMoving, batteryState)

    /** Re-issues the OS request when the effective interval or accuracy changed. */
    private fun reevaluateRequest(reason: String) {
        val svc = service ?: return
        val spec = Intervals.requestSpec(config, state.isMoving, batteryState)
        if (spec == activeSpec) return
        activeSpec = spec
        updatesRequestedAt = clock.nowMs()
        svc.applyRequest(spec)
        log.info(TAG, "location request: ${spec.accuracy.wire} accuracy every ${fmt(spec.intervalMs / 1000.0)} s ($reason)")
    }

    private fun onBatteryChanged(b: BatteryState) {
        batteryState = b
        reevaluateRequest("battery ${(b.level * 100).toInt()}%${if (b.isCharging) " charging" else ""}")
    }

    private fun tick() {
        val svc = service ?: return
        if (!state.enabled) {
            stopService()
            return
        }
        val now = clock.nowMs()
        val interval = currentIntervalMs()
        val reference = maxOf(state.lastFixTimeMs ?: 0L, updatesRequestedAt)
        if (Intervals.isLocationStale(now, reference, interval)) {
            log.warn(TAG, "no fix for ${(now - reference) / 1000} s (interval ${interval / 1000} s); restarting location updates")
            updatesRequestedAt = now
            svc.restartUpdates()
        }
        gate.checkOverdue(now, interval)?.let { onRecordDecision(it) }
        if (stateDirty || lastLocationDirty) persistState(durable = false, force = true)
        uploader.trigger(UploadTrigger.WATCHDOG)
        if (watchdogTicks++ % PRUNE_EVERY_TICKS == 0) pruneStorage()
        providers.check(null)
        refreshNotification(force = false)
    }

    private fun onProviderChange(provider: JSONObject) {
        log.info(TAG, "provider change: $provider")
        emit("providerchange", provider)
        if (!state.enabled) return
        if (!provider.optBoolean("enabled", true)) {
            emitError(ErrorCode.LOCATION_SERVICES_OFF, "location services were switched off; tracking continues when they are back")
        } else {
            resume("provider change")
        }
    }

    /** configure() / setConfig() on the app's layer; the server's overrides stay on top. */
    private fun applyLocalConfig(input: JSONObject, merge: Boolean, source: String) {
        val old = config
        val change = layers.setLocal(input, merge)
        prefs.saveConfig(layers.local.toJson().toString())
        config = layers.effective
        log.level = config.logLevel
        change.unknownKeys.forEach { log.debug(TAG, "$source: unknown key '$it' ignored") }
        log.info(TAG, "$source applied")
        change.droppedOverrides?.let {
            prefs.saveRemoteOverrides(layers.overridesJson)
            log.error(TAG, "server overrides cleared: they do not validate with this config (${it.message})")
        }
        applyLive(old, source)
    }

    private fun applyLive(old: LongPingConfig, source: String) {
        val next = config
        if (old.notification != next.notification || old.debug != next.debug) refreshNotification(force = true)
        reevaluateRequest(source)
        if (old.http != next.http) uploader.trigger(UploadTrigger.WATCHDOG)
    }

    /**
     * A `long_ping` reply: reset clears the server's overrides, then config merges into them. Only
     * a change of the effective config is applied live and emitted as `configchange`.
     */
    private fun applyRemote(d: RemoteDirective) {
        if (d.config != null || d.reset) {
            val old = config
            val change = layers.applyRemote(d.config, d.reset)
            if (d.reset) log.info(TAG, "server reset: overrides cleared")
            if (change.ignored) log.info(TAG, "server config ignored (remoteConfig is false)")
            if (change.remoteConfigKeyIgnored) log.warn(TAG, "server config: remoteConfig ignored (only the app sets it)")
            change.rejected?.let { log.warn(TAG, "server config rejected: ${it.message}") }
            change.unknownKeys.forEach { log.debug(TAG, "server config: unknown key '$it' ignored") }
            if (change.overridesChanged) prefs.saveRemoteOverrides(layers.overridesJson)
            if (change.effectiveChanged) {
                config = layers.effective
                log.level = config.logLevel
                log.info(TAG, "server config applied")
                applyLive(old, "server config")
                emit("configchange", config.toJson())
            } else if (d.config != null && !change.ignored && change.rejected == null) {
                log.debug(TAG, "server config: no change")
            }
        }
        if (d.stop && state.enabled) stopTracking("server sent long_ping.stop")
    }

    /**
     * lastRecordedTime is persisted at most every 30 s. After process death the newest queued
     * record or the last location can be later; the gate starts from them so the first fix after a
     * restart is not recorded too early.
     */
    private fun seedRecordingClock() {
        val newestQueued = try {
            queue.newestRecordedAt()
        } catch (e: Exception) {
            log.error(TAG, "queue unreadable", e)
            null
        }
        val resumeAt = RecordingGate.resumeTimeMs(state.lastRecordedTimeMs, newestQueued, lastLocationAt, clock.nowMs())
        if (resumeAt == state.lastRecordedTimeMs) return
        gate.seed(resumeAt)
        state = state.copy(lastRecordedTimeMs = resumeAt)
        if (resumeAt != null) log.debug(TAG, "interval clock resumes from ${Iso8601.format(resumeAt)} (newest stored record or last location)")
    }

    private fun stateJson(): JSONObject = JSONObject()
        .put("enabled", state.enabled)
        .put("isMoving", state.isMoving)
        .put("lastLocation", lastLocation ?: JSONObject.NULL)
        .put("lastLocationAt", lastLocationAt ?: JSONObject.NULL)
        .put("queueCount", countQueue())
        .put("authorizationRequired", uploader.authorizationRequired)
        .put("config", config.toJson())

    // ---------------------------------------------------------------- plumbing

    private fun refreshNotification(force: Boolean) {
        val svc = service ?: return
        if (!force && !config.debug) return
        val now = clock.nowMs()
        if (!force && now - lastNotificationAt < 1000) return
        lastNotificationAt = now
        countQueue()
        svc.updateNotification(notifications.build(config, notificationText()))
    }

    private fun notificationText(): String {
        val c = config
        return if (c.debug) NotificationText.debug(c.notification.text, clock.nowMs(), state.lastFixTimeMs, queueCountCache) else c.notification.text
    }

    private fun pruneStorage() {
        try {
            val pruned = queue.prune(config.persistence.maxRecords, clock.nowMs() - config.persistence.maxDays * DAY_MS)
            if (pruned.total > 0) log.warn(TAG, "queue pruned: ${pruned.overLimit} over maxRecords, ${pruned.expired} older than maxDays")
        } catch (e: Exception) {
            log.error(TAG, "queue prune failed", e)
        }
        log.prune(config.logMaxDays)
    }

    private fun countQueue(): Long = try {
        queue.count().also { queueCountCache = it }
    } catch (e: Exception) {
        log.error(TAG, "queue unreadable", e)
        queueCountCache
    }

    /**
     * Enabled flips are committed at once. Everything else (last fix/record times, last location)
     * is written at most every 30 s plus on every watchdog tick: at a 1 s interval writing on
     * every fix would rewrite the preferences file every second for little gain.
     */
    private fun persistState(durable: Boolean, force: Boolean = durable) {
        val now = clock.nowMs()
        if (!force && now - lastStatePersistAt < STATE_PERSIST_EVERY_MS) {
            stateDirty = true
            return
        }
        prefs.saveState(state.toJson().toString(), durable)
        lastLocation?.let { if (lastLocationDirty) prefs.saveLastLocation(it.toString(), lastLocationAt ?: now) }
        stateDirty = false
        lastLocationDirty = false
        lastStatePersistAt = now
    }

    internal fun emit(name: String, payload: JSONObject) {
        val s = sink ?: return
        try {
            s.emit(name, payload)
        } catch (e: Exception) {
            Log.w(Logger.LOGCAT_TAG, "event $name not delivered", e)
        }
    }

    private fun emitError(code: ErrorCode, message: String) {
        log.error(TAG, "${code.name}: $message")
        emit("error", JSONObject().put("code", code.name).put("message", message))
    }

    /** Runs [block] on the engine thread. An exception there would kill the host process, so it is logged instead. */
    private fun post(what: String, block: () -> Unit) {
        handler.post { guard(what, block) }
    }

    private inline fun guard(what: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            log.error(TAG, "$what failed", e)
        }
    }

    /** Runs [block] on the engine thread and reports the result; never lets an exception escape. */
    private fun <T> exec(cb: (Result<T>) -> Unit, block: () -> T) {
        handler.post {
            val result = try {
                Result.success(block())
            } catch (e: Exception) {
                Result.failure(asLongPing(e))
            }
            guard("result delivery") { cb(result) }
        }
    }

    private fun asLongPing(e: Exception): LongPingException {
        if (e is LongPingException) return e
        log.error(TAG, "internal error", e)
        return LongPingException(ErrorCode.INTERNAL, "${e.javaClass.simpleName}: ${e.message}", e)
    }

    private fun motionWord(moving: Boolean) = if (moving) "moving" else "parked"

    private fun describe(fix: Fix) = "±${fmt(fix.accuracy)} m, ${if (fix.speed >= 0) "${fmt(fix.speed)} m/s" else "speed unknown"}"

    private fun fmt(v: Double): String = if (v == Math.floor(v) && !v.isInfinite()) v.toLong().toString() else String.format(java.util.Locale.US, "%.1f", v)
}
