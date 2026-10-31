package com.longping.flutter

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import com.longping.core.ErrorCode
import com.longping.core.LongPingException
import com.longping.engine.EventSink
import com.longping.engine.LongPingEngine
import com.longping.engine.PermissionPrompt
import com.longping.engine.Permissions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject

/**
 * Flutter bridge: method channel `long_ping`, event channel `long_ping/events`. Only forwards to
 * [LongPingEngine], which runs with or without Flutter. Events go out only while Dart listens; nothing is
 * buffered. Method calls arrive on the main thread; every reply and event is posted back to it.
 */
class LongPingPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    EventSink {

    private lateinit var engine: LongPingEngine
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private var binding: ActivityPluginBinding? = null
    private val activity: Activity? get() = binding?.activity

    /** requestCode -> continuation of a permission dialog this plugin opened. Main thread only. */
    private val pendingPrompts = HashMap<Int, () -> Unit>()

    // ---------------------------------------------------------------- engine attach

    override fun onAttachedToEngine(flutter: FlutterPlugin.FlutterPluginBinding) {
        engine = LongPingEngine.get(flutter.applicationContext)
        methods = MethodChannel(flutter.binaryMessenger, METHOD_CHANNEL).also { it.setMethodCallHandler(this) }
        events = EventChannel(flutter.binaryMessenger, EVENT_CHANNEL).also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(flutter: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        eventSink = null
        engine.detachSink(this)
    }

    // ---------------------------------------------------------------- activity lifecycle

    // Background Flutter engines (no activity) never resume tracking: only the app's UI coming up counts as
    // an app launch, which also lifts a boot-time suppression (DESIGN.md, "Lifecycle and recovery").
    private val foreground = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(a: Activity) {
            if (a === activity) engine.resumeIfEnabled("app foreground", a)
        }

        override fun onActivityCreated(a: Activity, state: Bundle?) = Unit

        override fun onActivityStarted(a: Activity) = Unit

        override fun onActivityPaused(a: Activity) = Unit

        override fun onActivityStopped(a: Activity) = Unit

        override fun onActivitySaveInstanceState(a: Activity, state: Bundle) = Unit

        override fun onActivityDestroyed(a: Activity) = Unit
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
        engine.resumeIfEnabled("app launch", binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    private fun attach(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.activity.application.registerActivityLifecycleCallbacks(foreground)
    }

    private fun detach() {
        binding?.let {
            it.removeRequestPermissionsResultListener(this)
            it.activity.application.unregisterActivityLifecycleCallbacks(foreground)
        }
        binding = null
    }

    // ---------------------------------------------------------------- events

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
        engine.attachSink(this)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        engine.detachSink(this)
    }

    override fun emit(name: String, payload: JSONObject) {
        if (eventSink == null) return
        val event = mapOf("event" to name, "payload" to FlutterJson.toFlutter(payload))
        main.post { eventSink?.success(event) }
    }

    // ---------------------------------------------------------------- methods

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Argument conversion and dispatch must never throw out of a method call.
        try {
            when (call.method) {
                "configure" -> engine.configure(FlutterJson.toJson(call.arguments), result.reply())
                "setConfig" -> engine.setConfig(FlutterJson.toJson(call.arguments), result.reply())
                "start" -> engine.start(result.reply())
                "stop" -> engine.stop(result.reply())
                "getState" -> engine.getState(result.reply())
                "setAuthorization" -> engine.setAuthorization(FlutterJson.toJson(call.arguments), result.reply())
                "clearAuthorization" -> engine.clearAuthorization(result.reply())
                "getCurrentPosition" -> engine.getCurrentPosition(FlutterJson.toJson(call.arguments), result.reply())
                "changePace" -> engine.changePace(call.arguments == true, result.reply())
                "sync" -> engine.sync(result.reply())
                "getQueueCount" -> engine.getQueueCount(result.reply())
                "clearQueue" -> engine.clearQueue(result.reply())
                "getProviderState" -> engine.getProviderState(activity, result.reply())
                "requestPermission" -> requestPermission(call.arguments as? String, result)
                "isIgnoringBatteryOptimizations" ->
                    settings(result) { engine.deviceSettings.isIgnoringBatteryOptimizations() }
                "requestIgnoreBatteryOptimizations" ->
                    settings(result) { engine.deviceSettings.requestIgnoreBatteryOptimizations(activity) }
                "openPowerManagerSettings" ->
                    settings(result) { engine.deviceSettings.openPowerManagerSettings(activity) }
                "openAppSettings" -> settings(result) { engine.deviceSettings.openAppSettings(activity) }
                "openLocationSettings" -> settings(result) { engine.deviceSettings.openLocationSettings(activity) }
                "getLog" -> engine.getLog(FlutterJson.toJson(call.arguments), result.reply())
                "clearLog" -> engine.clearLog(result.reply())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.rejectWith(e)
        }
    }

    private fun requestPermission(level: String?, result: MethodChannel.Result) {
        val parsed = level?.let { Permissions.parseLevel(it) }
            ?: return result.error(ErrorCode.INVALID_CONFIG.name, "level: must be 'whenInUse' or 'always'", null)
        val current = activity
            ?: return result.error(ErrorCode.NO_ACTIVITY.name, "requestPermission needs a foreground activity", null)
        val prompt = PermissionPrompt { permissions, requestCode, onResult ->
            // The activity can be recreated between the foreground and the background request.
            val target = activity ?: return@PermissionPrompt onResult()
            // A second request with the same code settles the first instead of leaving its Future pending.
            pendingPrompts.put(requestCode, onResult)?.invoke()
            ActivityCompat.requestPermissions(target, permissions, requestCode)
        }
        try {
            engine.permissions.request(current, prompt, parsed) { status ->
                result.success(status)
                engine.onPermissionResult(status)
            }
        } catch (e: Exception) {
            result.error(ErrorCode.INTERNAL.name, "permission request failed: ${e.message}", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray): Boolean {
        val next = pendingPrompts.remove(requestCode) ?: return false
        next()
        return true
    }

    // ---------------------------------------------------------------- reply plumbing

    private fun settings(result: MethodChannel.Result, block: () -> Boolean) {
        try {
            result.success(block())
        } catch (e: Exception) {
            result.error(ErrorCode.INTERNAL.name, e.message ?: "settings screen failed", null)
        }
    }

    /** Engine callback (any thread) -> reply on the main thread. */
    private fun <T> MethodChannel.Result.reply(): (Result<T>) -> Unit = { outcome ->
        main.post {
            outcome.mapCatching { FlutterJson.toFlutter(it) }.fold(
                onSuccess = { success(it) },
                onFailure = { rejectWith(it) },
            )
        }
    }

    private fun MethodChannel.Result.rejectWith(t: Throwable) {
        val code = (t as? LongPingException)?.code ?: ErrorCode.INTERNAL
        error(code.name, t.message ?: code.name, null)
    }

    private companion object {
        const val METHOD_CHANNEL = "long_ping"
        const val EVENT_CHANNEL = "long_ping/events"
    }
}
