package com.longping.engine

import android.content.Context
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * WorkManager backstop (15 min, unique periodic): restarts the service if tracking is enabled
 * but the service is gone, and drains the upload queue while tracking is stopped.
 */
class LongPingWatchdogWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        try {
            LongPingEngine.get(applicationContext).onWatchdogWork()
        } catch (e: Throwable) {
            Log.e(Logger.LOGCAT_TAG, "watchdog work failed", e)
        }
        return Result.success()
    }
}

internal object WatchdogWork {
    private const val UNIQUE_NAME = "longping-watchdog"

    fun ensureScheduled(context: Context, log: Logger) {
        try {
            val request = PeriodicWorkRequest.Builder(LongPingWatchdogWorker::class.java, 15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(UNIQUE_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        } catch (e: Exception) {
            // Thrown when the host app disabled WorkManager's initializer without providing a
            // Configuration; the in-service watchdog still runs.
            log.warn("watchdog", "WorkManager unavailable; 15-min watchdog not scheduled", e)
        }
    }

    fun cancel(context: Context) {
        try {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_NAME)
        } catch (e: Exception) {
            Log.w(Logger.LOGCAT_TAG, "could not cancel watchdog work", e)
        }
    }
}
