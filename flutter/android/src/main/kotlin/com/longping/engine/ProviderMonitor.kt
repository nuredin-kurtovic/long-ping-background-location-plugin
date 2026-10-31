package com.longping.engine

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.os.Handler
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import org.json.JSONObject

/** ProviderState (DESIGN.md "Types") and `providerchange` events. */
internal class ProviderMonitor(
    private val context: Context,
    private val permissions: Permissions,
    private val deviceSettings: DeviceSettings,
    private val onChange: (JSONObject) -> Unit,
) {
    private var lastEmitted: String? = null
    private var receiver: BroadcastReceiver? = null

    fun isLocationEnabled(): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return LocationManagerCompat.isLocationEnabled(lm)
    }

    fun read(activity: Activity?): JSONObject {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        fun provider(name: String) = try {
            lm?.isProviderEnabled(name) ?: false
        } catch (e: Exception) {
            false
        }
        return JSONObject()
            .put("enabled", isLocationEnabled())
            .put("gps", provider(LocationManager.GPS_PROVIDER))
            .put("network", provider(LocationManager.NETWORK_PROVIDER))
            .put("status", permissions.status(activity))
            .put("accuracyAuthorization", if (permissions.hasFine()) "full" else "reduced")
            .put("powerSaveMode", pm?.isPowerSaveMode ?: false)
            .put("ignoringBatteryOptimizations", deviceSettings.isIgnoringBatteryOptimizations())
    }

    /** Emits `providerchange` if anything differs from the last emitted state. */
    fun check(activity: Activity?) {
        val state = read(activity)
        val text = state.toString()
        if (text != lastEmitted) {
            val first = lastEmitted == null
            lastEmitted = text
            if (!first) onChange(state)
        }
    }

    fun start(handler: Handler) {
        if (receiver != null) return
        check(null)
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                try {
                    check(null)
                } catch (e: Exception) {
                    // Runs on the engine thread: an escaping exception would kill the host process.
                    Log.w(Logger.LOGCAT_TAG, "provider check failed", e)
                }
            }
        }
        receiver = r
        val filter = IntentFilter().apply {
            addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
            addAction(LocationManager.MODE_CHANGED_ACTION)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        }
        ContextCompat.registerReceiver(context, r, filter, null, handler, ContextCompat.RECEIVER_NOT_EXPORTED)
    }
}
