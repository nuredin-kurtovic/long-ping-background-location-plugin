package com.longping.engine

import android.util.Log
import com.longping.core.Clock
import com.longping.core.LogLevel
import com.longping.core.LogQuery
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The on-device log (DESIGN.md principle 6, "explain every silence"). Entries go to SQLite on a
 * dedicated thread so a slow disk never delays a fix, and are mirrored to logcat.
 * Reads run on the same thread, after every pending write.
 */
internal class Logger(private val store: LogStore, private val clock: Clock) {
    @Volatile
    var level: LogLevel = LogLevel.INFO

    private val io: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "LongPing-log") }

    fun error(tag: String, message: String, t: Throwable? = null) = write(LogLevel.ERROR, tag, withCause(message, t))
    fun warn(tag: String, message: String, t: Throwable? = null) = write(LogLevel.WARN, tag, withCause(message, t))
    fun info(tag: String, message: String) = write(LogLevel.INFO, tag, message)
    fun debug(tag: String, message: String) = write(LogLevel.DEBUG, tag, message)

    fun isEnabled(l: LogLevel) = level.allows(l)

    private fun write(l: LogLevel, tag: String, message: String) {
        if (!level.allows(l)) return
        val ts = clock.nowMs()
        Log.println(priority(l), LOGCAT_TAG, "[$tag] $message")
        io.execute {
            try {
                store.insert(ts, l, tag, message)
            } catch (e: Exception) {
                Log.w(LOGCAT_TAG, "log write failed", e)
            }
        }
    }

    fun query(q: LogQuery, done: (Result<String>) -> Unit) = io.execute {
        done(runCatching { store.query(q) })
    }

    fun clear(done: (Result<Unit>) -> Unit) = io.execute {
        done(runCatching { store.clear(); Unit })
    }

    fun prune(logMaxDays: Int) = io.execute {
        try {
            val removed = store.prune(clock.nowMs() - logMaxDays * DAY_MS)
            if (removed > 0) Log.d(LOGCAT_TAG, "[log] pruned $removed entries older than $logMaxDays days")
        } catch (e: Exception) {
            Log.w(LOGCAT_TAG, "log prune failed", e)
        }
    }

    private fun withCause(message: String, t: Throwable?) =
        if (t == null) message else "$message (${t.javaClass.simpleName}: ${t.message})"

    private fun priority(l: LogLevel) = when (l) {
        LogLevel.ERROR -> Log.ERROR
        LogLevel.WARN -> Log.WARN
        LogLevel.DEBUG -> Log.DEBUG
        else -> Log.INFO
    }

    companion object {
        const val LOGCAT_TAG = "LongPing"
        const val DAY_MS = 86_400_000L
    }
}
