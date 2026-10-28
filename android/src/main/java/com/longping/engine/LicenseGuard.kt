package com.longping.engine

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import com.longping.core.EmulatorCheck
import com.longping.core.LicenseCheck
import com.longping.core.LicenseStatus
import com.longping.core.LicenseVerifier

/** License status for this app (checked at configure, start and native resume). */
internal class LicenseGuard(private val context: Context, private val log: Logger) {
    private val debugBuildOrEmulator: Boolean by lazy {
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        debuggable || EmulatorCheck.isEmulator(
            Build.FINGERPRINT ?: "", Build.MODEL ?: "", Build.MANUFACTURER ?: "", Build.BRAND ?: "",
            Build.DEVICE ?: "", Build.PRODUCT ?: "", Build.HARDWARE ?: "",
        )
    }
    private val verifier: LicenseVerifier? by lazy {
        try {
            LicenseVerifier()
        } catch (e: Exception) {
            log.error(TAG, "license verifier unavailable", e)
            null
        }
    }
    private var cachedKey: String? = null
    private var cachedCheck: LicenseCheck? = null
    private var loggedFor: Pair<String?, LicenseStatus>? = null

    @Synchronized
    fun status(key: String?, reason: String): LicenseStatus {
        val check = cachedCheck.takeIf { cachedKey == key } ?: run {
            val v = verifier
            val fresh = v?.verify(key, context.packageName) ?: LicenseCheck(LicenseStatus.INVALID, "verifier unavailable")
            cachedKey = key
            cachedCheck = fresh
            fresh
        }
        val status = LicenseVerifier.effectiveStatus(check, debugBuildOrEmulator)
        if (loggedFor != key to status) {
            loggedFor = key to status
            val line = "license ${status.wire} at $reason: ${check.reason}" + (check.subject?.let { " (customer $it)" } ?: "")
            if (LicenseVerifier.allowsTracking(status)) log.info(TAG, line) else log.error(TAG, line)
        }
        return status
    }

    fun reason(key: String?): String = synchronized(this) { cachedCheck.takeIf { cachedKey == key }?.reason } ?: "unknown"

    private companion object {
        const val TAG = "license"
    }
}
