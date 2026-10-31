package com.longping.core

import kotlin.math.max

data class MotionState(val isMoving: Boolean, val anchor: GeoPoint?, val parkedAt: GeoPoint?) {
    companion object {
        val PARKED_UNKNOWN = MotionState(isMoving = false, anchor = null, parkedAt = null)
    }
}

data class StopParams(
    val minAccuracyM: Double,
    val stopRadiusM: Double,
    val stopTimeoutSec: Double,
    val movingSpeedMps: Double,
    val disableStopDetection: Boolean,
) {
    companion object {
        fun from(c: LongPingConfig) =
            StopParams(c.minAccuracyM, c.stopRadiusM, c.stopTimeoutSec, c.movingSpeedMps, c.disableStopDetection)
    }
}

enum class MotionTransition { MOVED, PARKED }

/**
 * DESIGN.md, "Stop detection". Moving/parked comes only from the fixes (speed + displacement).
 *
 * Two readings of the contract made explicit here:
 * - Parked with no parked point (changePace(false) before any fix): the first evaluated fix
 *   becomes the parked point.
 * - disableStopDetection only disables parking; a forced park still ends on movement.
 */
class StopDetector(initial: MotionState) {
    var state: MotionState = initial
        private set

    fun evaluate(fix: Fix, p: StopParams): MotionTransition? {
        if (!fix.hasAccuracy || fix.accuracy > max(p.minAccuracyM, p.stopRadiusM)) return null
        val point = fix.toPoint()
        val s = state

        if (s.isMoving) {
            val anchor = s.anchor
            if (anchor == null || Geo.distanceM(anchor, point) > p.stopRadiusM || fix.speed >= p.movingSpeedMps) {
                state = s.copy(anchor = point)
                return null
            }
            if (!p.disableStopDetection && fix.timeMs - anchor.timeMs >= (p.stopTimeoutSec * 1000).toLong()) {
                state = MotionState(isMoving = false, anchor = null, parkedAt = point)
                return MotionTransition.PARKED
            }
            return null
        }

        val parkedAt = s.parkedAt
        if (parkedAt == null) {
            state = s.copy(parkedAt = point)
            return null
        }
        val bySpeed = fix.speed >= p.movingSpeedMps && fix.accuracy <= 50
        val byDistance = Geo.distanceM(parkedAt, point) > p.stopRadiusM && fix.accuracy <= p.stopRadiusM
        if (bySpeed || byDistance) {
            state = MotionState(isMoving = true, anchor = point, parkedAt = null)
            return MotionTransition.MOVED
        }
        return null
    }

    /** changePace / start: moving with anchor = [at] (may be null), or parked at [at]. */
    fun force(isMoving: Boolean, at: GeoPoint?) {
        state = if (isMoving) MotionState(true, anchor = at, parkedAt = null) else MotionState(false, anchor = null, parkedAt = at)
    }
}
