package com.longping.core

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/** What the OS location request should look like right now. Re-issue when it changes. */
data class LocationRequestSpec(val accuracy: Accuracy, val intervalMs: Long)

object Intervals {
    /** Overdue rule grace: an inaccurate fix may be recorded once this much past the interval. */
    const val OVERDUE_GRACE_MS = 30_000L

    /** DESIGN.md, "Effective interval". */
    fun effectiveIntervalSec(config: LongPingConfig, isMoving: Boolean, battery: BatteryState): Double {
        var base = if (isMoving) config.movingIntervalSec else config.parkedIntervalSec
        val low = config.lowBattery
        if (low != null && !battery.isCharging && battery.level >= 0 && battery.level * 100 < low.belowPct) {
            base = max(base, low.intervalSec)
        }
        return base
    }

    fun effectiveIntervalMs(config: LongPingConfig, isMoving: Boolean, battery: BatteryState): Long =
        (effectiveIntervalSec(config, isMoving, battery) * 1000).roundToLong()

    fun requestSpec(config: LongPingConfig, isMoving: Boolean, battery: BatteryState) =
        LocationRequestSpec(config.accuracy, effectiveIntervalMs(config, isMoving, battery))

    /** Recording tolerance: min(0.5 s, 10 % of the interval). */
    fun toleranceMs(intervalMs: Long): Long = min(500L, intervalMs / 10)

    /**
     * How long until a fix is due again: the first moment the recording rule accepts one. 0 when it
     * already is; null before anything was recorded (the next fix records regardless).
     */
    fun msUntilDue(lastRecordedMs: Long?, intervalMs: Long, nowMs: Long): Long? =
        lastRecordedMs?.let { max(0L, it + intervalMs - toleranceMs(intervalMs) - nowMs) }

    /**
     * Watchdog rule: no fix for longer than max(2 x interval, interval + 60 s) means the OS
     * request is stuck and must be re-issued. Before the first fix, pass the time updates were
     * requested as [lastFixMs].
     */
    fun isLocationStale(nowMs: Long, lastFixMs: Long, intervalMs: Long): Boolean =
        nowMs - lastFixMs > max(2 * intervalMs, intervalMs + 60_000L)
}
