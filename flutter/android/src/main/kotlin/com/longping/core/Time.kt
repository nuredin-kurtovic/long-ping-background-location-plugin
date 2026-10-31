package com.longping.core

/** Wall clock in epoch milliseconds. Core never reads the system time itself. */
fun interface Clock {
    fun nowMs(): Long
}

/**
 * ISO 8601 UTC formatting with millisecond precision (`2026-10-26T12:00:00.123Z`).
 *
 * Hand-rolled because java.time needs API 26 (minSdk is 24) and SimpleDateFormat is neither
 * thread-safe nor cheap enough to run on every fix.
 */
object Iso8601 {
    private const val MS_PER_DAY = 86_400_000L

    fun format(epochMs: Long): String {
        val days = Math.floorDiv(epochMs, MS_PER_DAY)
        val msOfDay = Math.floorMod(epochMs, MS_PER_DAY)
        val (year, month, day) = civilFromDays(days)
        val sb = StringBuilder(24)
        pad(sb, year, 4).append('-')
        pad(sb, month, 2).append('-')
        pad(sb, day, 2).append('T')
        pad(sb, (msOfDay / 3_600_000L).toInt(), 2).append(':')
        pad(sb, ((msOfDay / 60_000L) % 60).toInt(), 2).append(':')
        pad(sb, ((msOfDay / 1000L) % 60).toInt(), 2).append('.')
        pad(sb, (msOfDay % 1000L).toInt(), 3).append('Z')
        return sb.toString()
    }

    /** `YYYY-MM-DD` of the UTC day containing [epochMs]. */
    fun date(epochMs: Long): String = format(epochMs).substring(0, 10)

    // Howard Hinnant's days -> civil date algorithm (proleptic Gregorian, any epoch day).
    private fun civilFromDays(daysSinceEpoch: Long): Triple<Int, Int, Int> {
        val z = daysSinceEpoch + 719_468
        val era = Math.floorDiv(z, 146_097L)
        val doe = z - era * 146_097
        val yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val day = (doy - (153 * mp + 2) / 5 + 1).toInt()
        val month = (if (mp < 10) mp + 3 else mp - 9).toInt()
        val year = (yoe + era * 400 + if (month <= 2) 1 else 0).toInt()
        return Triple(year, month, day)
    }

    private fun pad(sb: StringBuilder, value: Int, width: Int): StringBuilder {
        val text = value.toString()
        for (i in text.length until width) sb.append('0')
        return sb.append(text)
    }
}
