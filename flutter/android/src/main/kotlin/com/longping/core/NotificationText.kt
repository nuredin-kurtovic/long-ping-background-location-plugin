package com.longping.core

/** Debug notification text: the configured text plus last-fix age and queue size. */
object NotificationText {
    fun debug(baseText: String, nowMs: Long, lastFixAtMs: Long?, queueCount: Long): String {
        val fix = if (lastFixAtMs == null) "no fix yet" else "fix ${age(nowMs - lastFixAtMs)} ago"
        return "$baseText · $fix · $queueCount queued"
    }

    fun age(ms: Long): String {
        val sec = maxOf(0L, ms / 1000)
        return when {
            sec < 60 -> "${sec}s"
            sec < 3600 -> "${sec / 60}m"
            else -> "${sec / 3600}h ${(sec % 3600) / 60}m"
        }
    }
}
