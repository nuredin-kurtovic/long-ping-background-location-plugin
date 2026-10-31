package com.longping.engine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** BOOT_COMPLETED / MY_PACKAGE_REPLACED -> resume tracking if enabled && startOnBoot. */
class LongPingBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        // Starting a foreground service from the background is only allowed while this broadcast
        // is being handled, so keep it open until the engine has tried.
        val pending = goAsync()
        try {
            LongPingEngine.get(context).onBoot(if (action == Intent.ACTION_BOOT_COMPLETED) "boot" else "app update") {
                pending.finish()
            }
        } catch (e: Throwable) {
            Log.e(Logger.LOGCAT_TAG, "boot handling failed", e)
            pending.finish()
        }
    }
}
