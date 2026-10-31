package com.longping.core

enum class RecordEvent(val wire: String) {
    INTERVAL("interval"),
    MOTIONCHANGE("motionchange"),
    CURRENT("current"),
}

/**
 * DESIGN.md, "Recording rule": decides which OS fixes become records.
 *
 * - Interval: accurate fix and `fix.time - lastRecorded >= interval - tolerance`.
 * - Overdue: more than interval + 30 s since the last record (or since tracking began) and only
 *   inaccurate fixes arrived -> record the most accurate one seen, accuracy waived.
 * - Motion change: the fix that changed the state is recorded immediately. A requested motion
 *   change (start / changePace) records the next accurate fix, or after [MOTIONCHANGE_GRACE_MS]
 *   the most accurate one seen.
 * - Fix time more than [CLOCK_JUMP_MS] *before* the last record means the clock moved backwards
 *   (wrong device time later corrected); the fix is recorded so tracking cannot go silent.
 */
class RecordingGate(lastRecordedTimeMs: Long? = null) {
    sealed class Decision {
        data class Record(val fix: Fix, val event: RecordEvent, val accuracyWaived: Boolean) : Decision()
        data class Skip(val reason: SkipReason) : Decision()
    }

    enum class SkipReason { INACCURATE, TOO_SOON }

    var lastRecordedTimeMs: Long? = lastRecordedTimeMs
        private set

    private var windowStartMs: Long? = null
    private var pendingMotionChangeSinceMs: Long? = null
    private var bestSinceRecord: Fix? = null

    val isMotionChangePending: Boolean get() = pendingMotionChangeSinceMs != null

    /** Engine start: the interval clock from [resumeTimeMs]. */
    fun seed(lastRecordedTimeMs: Long?) {
        this.lastRecordedTimeMs = lastRecordedTimeMs
    }

    /** Tracking (re)started at [nowMs]: the overdue clock runs from here until the first record. */
    fun beginWindow(nowMs: Long) {
        windowStartMs = nowMs
        bestSinceRecord = null
    }

    fun requestMotionChange(nowMs: Long) {
        pendingMotionChangeSinceMs = nowMs
        bestSinceRecord = null
    }

    fun cancelMotionChange() {
        pendingMotionChangeSinceMs = null
    }

    /**
     * changePace() with a fix that stands for "here, now" (see [forcedMotionFix]): the motion
     * change is recorded at once with it, like a detector transition.
     */
    fun recordMotionChange(fix: Fix): Decision.Record = record(fix, RecordEvent.MOTIONCHANGE, waived = false)

    fun offer(fix: Fix, nowMs: Long, intervalMs: Long, minAccuracyM: Double, motionChanged: Boolean = false): Decision {
        val accurate = isAccurate(fix, minAccuracyM)
        if (motionChanged) return record(fix, RecordEvent.MOTIONCHANGE, waived = !accurate)

        val pendingSince = pendingMotionChangeSinceMs
        if (pendingSince != null) {
            if (accurate) return record(fix, RecordEvent.MOTIONCHANGE, waived = false)
            val best = remember(fix)
            return if (nowMs - pendingSince >= MOTIONCHANGE_GRACE_MS) {
                record(best, RecordEvent.MOTIONCHANGE, waived = true)
            } else {
                Decision.Skip(SkipReason.INACCURATE)
            }
        }

        if (!accurate) {
            remember(fix)
            return overdue(nowMs, intervalMs) ?: Decision.Skip(SkipReason.INACCURATE)
        }

        val last = lastRecordedTimeMs
        val due = last == null ||
            fix.timeMs - last >= intervalMs - Intervals.toleranceMs(intervalMs) ||
            fix.timeMs < last - CLOCK_JUMP_MS
        return if (due) record(fix, RecordEvent.INTERVAL, waived = false) else Decision.Skip(SkipReason.TOO_SOON)
    }

    /** Overdue check without a new fix (watchdog tick). */
    fun checkOverdue(nowMs: Long, intervalMs: Long): Decision.Record? = overdue(nowMs, intervalMs)

    private fun overdue(nowMs: Long, intervalMs: Long): Decision.Record? {
        val best = bestSinceRecord ?: return null
        val reference = lastRecordedTimeMs ?: windowStartMs ?: return null
        if (nowMs - reference <= intervalMs + Intervals.OVERDUE_GRACE_MS) return null
        return record(best, RecordEvent.INTERVAL, waived = true)
    }

    private fun remember(fix: Fix): Fix {
        val best = bestSinceRecord
        val winner = if (best == null || moreAccurate(fix, best)) fix else best
        bestSinceRecord = winner
        return winner
    }

    private fun record(fix: Fix, event: RecordEvent, waived: Boolean): Decision.Record {
        lastRecordedTimeMs = fix.timeMs
        bestSinceRecord = null
        pendingMotionChangeSinceMs = null
        return Decision.Record(fix, event, waived)
    }

    companion object {
        const val MOTIONCHANGE_GRACE_MS = 30_000L
        const val CLOCK_JUMP_MS = 10 * 60_000L

        /** A last fix at most this old still stands for "here, now" when changePace() is called. */
        const val FRESH_FIX_MS = 10_000L

        /**
         * changePace(): the last fix if it is fresh and accurate, else null. That fix is both the
         * detector's new anchor / parked point and the motionchange record, written at once. With
         * null the detector gets no point and the change waits for the next fix, which then
         * becomes the point. A stale point must never be used: the first new fix would be judged
         * against it (e.g. "parked" 30 s ago, now 15 m/s away) and undo the forced state before it
         * was ever recorded, so the requested motionchange would be lost.
         */
        fun forcedMotionFix(lastFix: Fix?, nowMs: Long, minAccuracyM: Double): Fix? =
            lastFix?.takeIf { nowMs - it.timeMs <= FRESH_FIX_MS && isAccurate(it, minAccuracyM) }

        /**
         * The interval clock when the engine starts. lastRecordedTime is persisted at most every
         * 30 s, so after process death the newest queued record or the last location can be later;
         * without them the first fix after a restart could be recorded too early (Android e2e S12).
         * Capped at [nowMs]: a clock set back must not hold new fixes.
         */
        fun resumeTimeMs(persistedMs: Long?, newestQueuedMs: Long?, lastLocationAtMs: Long?, nowMs: Long): Long? =
            listOfNotNull(persistedMs, newestQueuedMs, lastLocationAtMs).maxOrNull()?.let { minOf(it, nowMs) }

        fun isAccurate(fix: Fix, minAccuracyM: Double): Boolean =
            minAccuracyM == 0.0 || (fix.hasAccuracy && fix.accuracy <= minAccuracyM)

        /** Known accuracy beats unknown; smaller beats larger; ties go to the newer fix. */
        fun moreAccurate(candidate: Fix, current: Fix): Boolean = when {
            !candidate.hasAccuracy -> false
            !current.hasAccuracy -> true
            candidate.accuracy != current.accuracy -> candidate.accuracy < current.accuracy
            else -> candidate.timeMs >= current.timeMs
        }
    }
}
