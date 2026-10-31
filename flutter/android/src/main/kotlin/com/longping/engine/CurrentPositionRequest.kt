package com.longping.engine

import android.content.Context
import android.os.Handler
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.longping.core.Clock
import com.longping.core.CurrentPositionOptions
import com.longping.core.CurrentPositionPolicy
import com.longping.core.ErrorCode
import com.longping.core.Fix
import com.longping.core.LongPingException
import java.util.concurrent.Executor

/**
 * getCurrentPosition(): its own fused request, independent of tracking. Runs entirely on the
 * engine [handler]. Answers the first fix passing minAccuracyM; on timeout the best fix seen,
 * else a last-known fix younger than 10 min, else TIMEOUT.
 */
internal class CurrentPositionRequest(
    context: Context,
    private val handler: Handler,
    private val clock: Clock,
    private val options: CurrentPositionOptions,
    private val minAccuracyM: Double,
    engineLastFix: Fix?,
    private val done: (Result<Fix>) -> Unit,
) {
    private val client = LocationServices.getFusedLocationProviderClient(context)
    private val executor = Executor { handler.post(it) }
    private var lastKnown: Fix? = engineLastFix
    private var best: Fix? = null
    private var finished = false
    private val timeout = Runnable { finishOnTimeout() }

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            for (l in result.locations) {
                val fix = LocationMapper.toFix(l)
                best = CurrentPositionPolicy.better(best, fix)
                if (CurrentPositionPolicy.isGoodEnough(fix, minAccuracyM)) {
                    finish(Result.success(fix))
                    return
                }
            }
        }
    }

    fun start() {
        CurrentPositionPolicy.cached(lastKnown, clock.nowMs(), options.maximumAgeMs)?.let {
            finish(Result.success(it))
            return
        }
        try {
            client.lastLocation.addOnSuccessListener(executor) { l ->
                if (l != null) lastKnown = CurrentPositionPolicy.newest(lastKnown, LocationMapper.toFix(l))
                if (!finished) CurrentPositionPolicy.cached(lastKnown, clock.nowMs(), options.maximumAgeMs)?.let { finish(Result.success(it)) }
            }
            val request = LocationRequest.Builder(LocationMapper.priority(options.accuracy), 1000L)
                .setMinUpdateIntervalMillis(500L)
                .setMaxUpdateAgeMillis(options.maximumAgeMs)
                .setDurationMillis(options.timeoutMs + 1000L)
                .setWaitForAccurateLocation(false)
                .build()
            client.requestLocationUpdates(request, callback, handler.looper)
                .addOnFailureListener(executor) { e -> finish(Result.failure(LongPingException(ErrorCode.INTERNAL, "location request failed: ${e.message}", e))) }
            handler.postDelayed(timeout, options.timeoutMs)
        } catch (e: SecurityException) {
            finish(Result.failure(LongPingException(ErrorCode.PERMISSION_DENIED, "location permission not granted", e)))
        } catch (e: Exception) {
            finish(Result.failure(LongPingException(ErrorCode.INTERNAL, "location request failed: ${e.message}", e)))
        }
    }

    private fun finishOnTimeout() {
        val fix = CurrentPositionPolicy.onTimeout(best, lastKnown, clock.nowMs())
        finish(
            if (fix != null) Result.success(fix)
            else Result.failure(LongPingException(ErrorCode.TIMEOUT, "no location within ${options.timeoutSec.toLong()} s")),
        )
    }

    private fun finish(result: Result<Fix>) {
        if (finished) return
        finished = true
        handler.removeCallbacks(timeout)
        try {
            client.removeLocationUpdates(callback)
        } catch (e: Exception) {
            // Nothing to clean up if the request never registered.
        }
        done(result)
    }
}
