package com.longping.engine

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import com.longping.core.PowerManagerTargets

/** Battery-optimisation, OEM power-manager, app and location settings screens. Every method resolves to "did a screen open". */
internal class DeviceSettings(private val context: Context) {
    private val pm: PackageManager get() = context.packageManager

    fun isIgnoringBatteryOptimizations(): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * The direct "allow" dialog needs REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, which the app must
     * declare itself (Play policy); without it, open the general list instead.
     */
    @SuppressLint("BatteryLife")
    fun requestIgnoreBatteryOptimizations(activity: Activity?): Boolean {
        if (declaresPermission(Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)) {
            val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
            if (launch(direct, activity)) return true
        }
        return launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), activity)
    }

    /**
     * First OEM power / auto-start screen that resolves (and is exported), else app details.
     * Resolving these needs the manifest's <queries> package entries on Android 11+.
     */
    fun openPowerManagerSettings(activity: Activity?): Boolean {
        for (target in PowerManagerTargets.ALL) {
            val intent = Intent().setComponent(ComponentName(target.packageName, target.className))
            val info = resolve(intent) ?: continue
            if (!info.activityInfo.exported) continue
            if (launch(intent, activity)) return true
        }
        return openAppSettings(activity)
    }

    fun openAppSettings(activity: Activity?): Boolean =
        launch(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")), activity)

    fun openLocationSettings(activity: Activity?): Boolean = launch(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS), activity)

    /**
     * System settings screens are started directly: on Android 11+ resolveActivity() can report
     * them missing (package visibility) even though they open fine. A missing screen surfaces as
     * ActivityNotFoundException.
     */
    private fun launch(intent: Intent, activity: Activity?): Boolean = try {
        if (activity != null) {
            activity.startActivity(intent)
        } else {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false // some OEM screens resolve but are protected by a signature permission
    }

    @Suppress("DEPRECATION")
    private fun resolve(intent: Intent) = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.resolveActivity(intent, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()))
        } else {
            pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }
    } catch (e: Exception) {
        null
    }

    @Suppress("DEPRECATION")
    private fun declaresPermission(permission: String): Boolean = try {
        val info: PackageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()))
        } else {
            pm.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        }
        info.requestedPermissions?.contains(permission) == true
    } catch (e: Exception) {
        false
    }
}
