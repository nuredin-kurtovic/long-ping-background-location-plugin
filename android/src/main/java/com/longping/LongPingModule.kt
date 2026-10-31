package com.longping

import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.modules.core.PermissionAwareActivity
import com.longping.core.ErrorCode
import com.longping.core.LongPingException
import com.longping.engine.EventSink
import com.longping.engine.LongPingEngine
import com.longping.engine.PermissionPrompt
import com.longping.engine.Permissions
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

/**
 * TurboModule `LongPing`. Only forwards to [LongPingEngine], which runs with or without React.
 * Events go out only while JS has listeners; nothing is buffered.
 */
@ReactModule(name = NativeLongPingSpec.NAME)
class LongPingModule(reactContext: ReactApplicationContext) :
    NativeLongPingSpec(reactContext), EventSink, LifecycleEventListener {

    private val engine = LongPingEngine.get(reactContext)
    private val listeners = AtomicInteger(0)

    override fun initialize() {
        super.initialize()
        engine.attachSink(this)
        reactApplicationContext.addLifecycleEventListener(this)
        engine.resumeIfEnabled("app launch", reactApplicationContext.currentActivity)
    }

    override fun invalidate() {
        engine.detachSink(this)
        reactApplicationContext.removeLifecycleEventListener(this)
        super.invalidate()
    }

    // ---------------------------------------------------------------- lifecycle

    override fun onHostResume() = engine.resumeIfEnabled("app foreground", reactApplicationContext.currentActivity)

    override fun onHostPause() = Unit

    override fun onHostDestroy() = Unit

    // ---------------------------------------------------------------- events

    override fun emit(name: String, payload: JSONObject) {
        if (listeners.get() <= 0) return
        val context = reactApplicationContext
        if (!context.hasActiveReactInstance()) return
        context.emitDeviceEvent(name, ReactJson.toWritableMap(payload))
    }

    override fun addListener(eventName: String) {
        listeners.incrementAndGet()
    }

    override fun removeListeners(count: Double) {
        listeners.updateAndGet { maxOf(0, it - count.toInt()) }
    }

    // ---------------------------------------------------------------- spec methods

    override fun configure(config: ReadableMap, promise: Promise) = call(promise) { engine.configure(ReactJson.toJson(config), promise.asMap()) }

    override fun setConfig(config: ReadableMap, promise: Promise) = call(promise) { engine.setConfig(ReactJson.toJson(config), promise.asMap()) }

    override fun start(promise: Promise) = call(promise) { engine.start(promise.asMap()) }

    override fun stop(promise: Promise) = call(promise) { engine.stop(promise.asMap()) }

    override fun getState(promise: Promise) = call(promise) { engine.getState(promise.asMap()) }

    override fun setAuthorization(auth: ReadableMap, promise: Promise) = call(promise) { engine.setAuthorization(ReactJson.toJson(auth), promise.asVoid()) }

    override fun clearAuthorization(promise: Promise) = call(promise) { engine.clearAuthorization(promise.asVoid()) }

    override fun getCurrentPosition(options: ReadableMap, promise: Promise) = call(promise) { engine.getCurrentPosition(ReactJson.toJson(options), promise.asMap()) }

    override fun changePace(isMoving: Boolean, promise: Promise) = call(promise) { engine.changePace(isMoving, promise.asMap()) }

    override fun sync(promise: Promise) = call(promise) { engine.sync(promise.adapt { it.toDouble() }) }

    override fun getQueueCount(promise: Promise) = call(promise) { engine.getQueueCount(promise.adapt { it.toDouble() }) }

    override fun clearQueue(promise: Promise) = call(promise) { engine.clearQueue(promise.asVoid()) }

    override fun getProviderState(promise: Promise) = call(promise) { engine.getProviderState(reactApplicationContext.currentActivity, promise.asMap()) }

    override fun requestPermission(level: String, promise: Promise) {
        val parsed = Permissions.parseLevel(level)
            ?: return promise.reject(ErrorCode.INVALID_CONFIG.name, "level: must be 'whenInUse' or 'always'")
        val activity = reactApplicationContext.currentActivity
        val aware = activity as? PermissionAwareActivity
        if (activity == null || aware == null) {
            promise.reject(ErrorCode.NO_ACTIVITY.name, "requestPermission needs a foreground activity that implements PermissionAwareActivity (ReactActivity does)")
            return
        }
        val prompt = PermissionPrompt { permissions, requestCode, onResult ->
            aware.requestPermissions(permissions, requestCode) { _, _, _ ->
                onResult()
                true
            }
        }
        UiThreadUtil.runOnUiThread {
            try {
                engine.permissions.request(activity, prompt, parsed) { status ->
                    promise.resolve(status)
                    engine.onPermissionResult(status)
                }
            } catch (e: Exception) {
                promise.reject(ErrorCode.INTERNAL.name, "permission request failed: ${e.message}", e)
            }
        }
    }

    override fun isIgnoringBatteryOptimizations(promise: Promise) =
        settings(promise) { engine.deviceSettings.isIgnoringBatteryOptimizations() }

    override fun requestIgnoreBatteryOptimizations(promise: Promise) =
        settings(promise) { engine.deviceSettings.requestIgnoreBatteryOptimizations(reactApplicationContext.currentActivity) }

    override fun openPowerManagerSettings(promise: Promise) =
        settings(promise) { engine.deviceSettings.openPowerManagerSettings(reactApplicationContext.currentActivity) }

    override fun openAppSettings(promise: Promise) =
        settings(promise) { engine.deviceSettings.openAppSettings(reactApplicationContext.currentActivity) }

    override fun openLocationSettings(promise: Promise) =
        settings(promise) { engine.deviceSettings.openLocationSettings(reactApplicationContext.currentActivity) }

    override fun getLog(options: ReadableMap, promise: Promise) = call(promise) { engine.getLog(ReactJson.toJson(options), promise.adapt { it }) }

    override fun clearLog(promise: Promise) = call(promise) { engine.clearLog(promise.asVoid()) }

    // ---------------------------------------------------------------- promise plumbing

    /** Argument conversion and dispatch must never throw out of a TurboModule method. */
    private inline fun call(promise: Promise, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            promise.rejectWith(e)
        }
    }

    private fun settings(promise: Promise, block: () -> Boolean) {
        try {
            promise.resolve(block())
        } catch (e: Exception) {
            promise.reject(ErrorCode.INTERNAL.name, e.message ?: "settings screen failed", e)
        }
    }

    private fun Promise.asMap(): (Result<JSONObject>) -> Unit = adapt { ReactJson.toWritableMap(it) }

    private fun Promise.asVoid(): (Result<Unit>) -> Unit = adapt { null }

    private fun <T> Promise.adapt(convert: (T) -> Any?): (Result<T>) -> Unit = { result ->
        result.fold(
            onSuccess = { value ->
                try {
                    resolve(convert(value))
                } catch (e: Exception) {
                    rejectWith(e)
                }
            },
            onFailure = { rejectWith(it) },
        )
    }

    private fun Promise.rejectWith(t: Throwable) {
        val code = (t as? LongPingException)?.code ?: ErrorCode.INTERNAL
        reject(code.name, t.message ?: code.name, t)
    }
}
