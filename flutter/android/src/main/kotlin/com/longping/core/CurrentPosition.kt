package com.longping.core

import org.json.JSONObject

/** getCurrentPosition() options (DESIGN.md: timeoutSec 30, maximumAgeSec 0, accuracy, persist, extras). */
data class CurrentPositionOptions(
    val timeoutSec: Double = 30.0,
    val maximumAgeSec: Double = 0.0,
    val accuracy: Accuracy,
    val persist: Boolean = false,
    val extras: JSONObject? = null,
) {
    val timeoutMs: Long get() = (timeoutSec * 1000).toLong()
    val maximumAgeMs: Long get() = (maximumAgeSec * 1000).toLong()

    companion object {
        fun parse(options: JSONObject, configAccuracy: Accuracy): CurrentPositionOptions {
            fun number(key: String, default: Double): Double {
                val v = Json.value(options, key) ?: return default
                val d = (v as? Number)?.toDouble() ?: throw ConfigException(key, "must be a number")
                if (d.isNaN() || d.isInfinite()) throw ConfigException(key, "must be a finite number")
                return d
            }
            val accuracy = when (val a = Json.value(options, "accuracy")) {
                null -> configAccuracy
                is String -> Accuracy.entries.firstOrNull { it.wire == a }
                    ?: throw ConfigException("accuracy", "must be 'high', 'balanced' or 'low'")
                else -> throw ConfigException("accuracy", "must be a string")
            }
            val persist = when (val p = Json.value(options, "persist")) {
                null -> false
                is Boolean -> p
                else -> throw ConfigException("persist", "must be a boolean")
            }
            val extras = when (val e = Json.value(options, "extras")) {
                null -> null
                is JSONObject -> Json.copy(e)
                else -> throw ConfigException("extras", "must be an object")
            }
            return CurrentPositionOptions(
                timeoutSec = number("timeoutSec", 30.0).coerceIn(1.0, 600.0),
                maximumAgeSec = number("maximumAgeSec", 0.0).coerceAtLeast(0.0),
                accuracy = accuracy,
                persist = persist,
                extras = extras,
            )
        }
    }
}

/**
 * One-shot position rules:
 * - a cached fix no older than maximumAgeSec answers immediately;
 * - the first fix passing minAccuracyM (any fix when 0) answers early;
 * - on timeout: the most accurate fix seen in the window, else the last known fix if younger than
 *   10 minutes, else TIMEOUT.
 */
object CurrentPositionPolicy {
    const val LAST_KNOWN_MAX_AGE_MS = 10 * 60_000L

    fun cached(lastKnown: Fix?, nowMs: Long, maximumAgeMs: Long): Fix? =
        lastKnown?.takeIf { maximumAgeMs > 0 && nowMs - it.timeMs <= maximumAgeMs }

    fun isGoodEnough(fix: Fix, minAccuracyM: Double): Boolean = RecordingGate.isAccurate(fix, minAccuracyM)

    fun better(current: Fix?, candidate: Fix): Fix =
        if (current == null || RecordingGate.moreAccurate(candidate, current)) candidate else current

    fun onTimeout(bestSeen: Fix?, lastKnown: Fix?, nowMs: Long): Fix? =
        bestSeen ?: lastKnown?.takeIf { nowMs - it.timeMs < LAST_KNOWN_MAX_AGE_MS }

    /** The newer of two candidate last-known fixes. */
    fun newest(a: Fix?, b: Fix?): Fix? = when {
        a == null -> b
        b == null -> a
        b.timeMs > a.timeMs -> b
        else -> a
    }
}
