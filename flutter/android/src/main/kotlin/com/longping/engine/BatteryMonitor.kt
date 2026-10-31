package com.longping.engine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Handler
import androidx.core.content.ContextCompat
import com.longping.core.BatteryState

/** Battery level / charging from the sticky ACTION_BATTERY_CHANGED intent. */
internal class BatteryMonitor(private val context: Context) {
    private var receiver: BroadcastReceiver? = null
    private var last: BatteryState? = null

    fun current(): BatteryState = read(stickyIntent())

    /** Calls [onChange] (on [handler]) when the percentage or charging state changes. */
    fun start(handler: Handler, onChange: (BatteryState) -> Unit) {
        if (receiver != null) return
        last = current()
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                val next = read(intent)
                val prev = last
                // The broadcast also fires for temperature and voltage changes; only level/charging matter.
                if (prev == null || prev.isCharging != next.isCharging || percent(prev) != percent(next)) {
                    last = next
                    onChange(next)
                }
            }
        }
        receiver = r
        ContextCompat.registerReceiver(context, r, IntentFilter(Intent.ACTION_BATTERY_CHANGED), null, handler, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    fun stop() {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
    }

    private fun stickyIntent(): Intent? = try {
        ContextCompat.registerReceiver(context, null, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
    } catch (e: Exception) {
        null
    }

    private fun read(intent: Intent?): BatteryState {
        if (intent == null) return BatteryState.UNKNOWN
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        val charging = plugged != 0 || status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return BatteryState.fromRaw(intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1), charging)
    }

    private fun percent(b: BatteryState) = (b.level * 100).toInt()
}
