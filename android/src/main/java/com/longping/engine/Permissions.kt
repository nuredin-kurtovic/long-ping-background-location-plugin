package com.longping.engine

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.longping.core.AuthorizationStatus

/**
 * Shows the system dialog for [permissions] and calls [onResult] once the user has answered. Each bridge
 * supplies its own (React Native: PermissionAwareActivity; Flutter: the activity binding), so the engine
 * stays free of either.
 */
internal fun interface PermissionPrompt {
    fun request(permissions: Array<String>, requestCode: Int, onResult: () -> Unit)
}

/** Location permission state and the one prompt flow (requestPermission is the only call that prompts). */
internal class Permissions(private val context: Context, private val prefs: EnginePrefs) {
    enum class Level { WHEN_IN_USE, ALWAYS }

    fun hasFine() = granted(Manifest.permission.ACCESS_FINE_LOCATION)

    fun hasForeground() = hasFine() || granted(Manifest.permission.ACCESS_COARSE_LOCATION)

    /** Below Android 10 there is no separate background permission: foreground access covers it. */
    fun hasBackground() =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) hasForeground() else granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    /** Rationale needs an activity; without one the last answer seen is reused so the status does not flap. */
    @Volatile
    private var lastRationale = false

    fun status(activity: Activity?): Int {
        val fg = hasForeground()
        val rationale = when {
            fg -> false
            activity != null -> (
                activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION) ||
                    activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION)
                ).also { lastRationale = it }
            else -> lastRationale
        }
        return AuthorizationStatus.android(fg, fg && hasBackground(), prefs.permissionAsked, rationale)
    }

    /**
     * Foreground first, then (for ALWAYS, Android 10+) background. On Android 11+ the background
     * request opens the system settings page; its result arrives when the user comes back.
     * Must be called on the main thread.
     */
    fun request(activity: Activity, prompt: PermissionPrompt, level: Level, done: (Int) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        val finish = { done(status(activity)) }

        val requestBackground = {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || hasBackground()) {
                finish()
            } else {
                prompt.request(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), REQUEST_BACKGROUND) { finish() }
            }
        }

        if (hasForeground()) {
            if (level == Level.ALWAYS) requestBackground() else finish()
            return
        }
        prefs.permissionAsked = true
        prompt.request(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            REQUEST_FOREGROUND,
        ) {
            // ReactActivityDelegate clears its listener after this callback returns, so a second
            // request issued from inside the callback would lose its listener: post it.
            if (level == Level.ALWAYS && hasForeground()) main.post { requestBackground() } else finish()
        }
    }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        const val REQUEST_FOREGROUND = 0x4C01
        const val REQUEST_BACKGROUND = 0x4C02

        fun parseLevel(value: String): Level? = when (value) {
            "whenInUse" -> Level.WHEN_IN_USE
            "always" -> Level.ALWAYS
            else -> null
        }
    }
}

/**
 * Whether an activity of the app is visible, i.e. a service started now gets while-in-use location.
 * FOREGROUND_SERVICE importance (125, e.g. the host's own media service) does not count.
 */
internal object AppVisibility {
    fun isVisible(): Boolean = try {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
            info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    } catch (e: Exception) {
        false
    }
}
