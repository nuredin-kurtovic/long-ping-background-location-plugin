package com.longping.engine

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationAvailability
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.tasks.CancellationTokenSource
import com.longping.core.Accuracy
import com.longping.core.LocationRequestSpec
import java.util.concurrent.Executor

/**
 * The foreground service (type location) that keeps the process alive and owns the
 * FusedLocationProviderClient request. All decisions live in [LongPingEngine]; location callbacks
 * are delivered straight onto the engine's looper.
 *
 * Methods other than lifecycle callbacks are called by the engine on its thread.
 */
class LongPingService : Service() {
    private lateinit var engine: LongPingEngine
    private var fused: FusedLocationProviderClient? = null
    private var activeSpec: LocationRequestSpec? = null
    private var immediate: CancellationTokenSource? = null
    private var lastStartId = 0

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) = engine.onLocations(result.locations)

        override fun onLocationAvailability(availability: LocationAvailability) =
            engine.onLocationAvailability(availability.isLocationAvailable)
    }

    override fun onCreate() {
        super.onCreate()
        engine = LongPingEngine.get(this)
        fused = try {
            LocationServices.getFusedLocationProviderClient(this)
        } catch (e: Exception) {
            engine.onLocationRequestFailed(e)
            null
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        // startForeground must come first: a service started with startForegroundService() that
        // stops before calling it crashes the app ("did not then call Service.startForeground()").
        // Stopping by start id keeps a newer, still undelivered start from being torn down with it.
        if (!enterForeground()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        engine.onServiceStarted(this, restartedBySystem = intent == null)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        engine.onTaskRemoved()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        removeUpdates()
        immediate?.cancel()
        engine.onServiceDestroyed(this)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun enterForeground(): Boolean = try {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
        ServiceCompat.startForeground(this, TrackingNotification.ID, engine.currentNotification(), type)
        true
    } catch (e: Exception) {
        // Android 12+: ForegroundServiceStartNotAllowedException (started from the background
        // without an exemption, e.g. a sticky restart). Android 14+: SecurityException when the
        // location permission is missing or only while-in-use while the app is not visible.
        engine.onServiceStartFailed(e)
        false
    }

    /** (Re)issues the continuous request. Same callback = the previous request is replaced, no gap. */
    internal fun applyRequest(spec: LocationRequestSpec) {
        val client = fused ?: return
        activeSpec = spec
        val request = LocationRequest.Builder(LocationMapper.priority(spec.accuracy), spec.intervalMs)
            .setMinUpdateIntervalMillis(spec.intervalMs)
            .setMaxUpdateDelayMillis(0)
            .setWaitForAccurateLocation(false)
            .build()
        try {
            client.requestLocationUpdates(request, callback, engine.looper)
                .addOnFailureListener { e -> engine.onLocationRequestFailed(e) }
        } catch (e: SecurityException) {
            engine.onLocationRequestFailed(e)
        }
    }

    /** Watchdog: drop and re-register the request (a stuck provider often recovers this way). */
    internal fun restartUpdates() {
        val spec = activeSpec ?: return
        removeUpdates()
        applyRequest(spec)
    }

    /** One fresh fix now (start / changePace), delivered through the normal pipeline. */
    internal fun requestImmediateFix(accuracy: Accuracy) {
        val client = fused ?: return
        immediate?.cancel()
        val cts = CancellationTokenSource().also { immediate = it }
        val request = CurrentLocationRequest.Builder()
            .setPriority(LocationMapper.priority(accuracy))
            .setMaxUpdateAgeMillis(0)
            .setDurationMillis(IMMEDIATE_FIX_TIMEOUT_MS)
            .build()
        val onEngine = Executor { engine.handler.post(it) }
        try {
            client.getCurrentLocation(request, cts.token)
                .addOnSuccessListener(onEngine) { l -> if (l != null) engine.onLocations(listOf(l)) }
                .addOnFailureListener(onEngine) { e -> engine.onLocationRequestFailed(e) }
        } catch (e: SecurityException) {
            engine.onLocationRequestFailed(e)
        }
    }

    internal fun updateNotification(notification: Notification) = engine.notifications.post(notification)

    /** Stops unless a newer start is already queued (that start re-checks with the engine). */
    internal fun shutdown() {
        removeUpdates()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf(lastStartId)
    }

    private fun removeUpdates() {
        try {
            fused?.removeLocationUpdates(callback)
        } catch (e: Exception) {
            // Not registered: nothing to remove.
        }
    }

    private companion object {
        const val IMMEDIATE_FIX_TIMEOUT_MS = 30_000L
    }
}
