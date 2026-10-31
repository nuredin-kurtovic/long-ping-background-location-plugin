package com.longping.core

import org.json.JSONObject

/** Log line format: `2026-10-26T12:00:00.123Z INFO  [tag] message`, one entry per line. */
object LogFormat {
    fun line(timestampMs: Long, level: LogLevel, tag: String, message: String): String =
        "${Iso8601.format(timestampMs)} ${level.label.padEnd(5)} [$tag] ${singleLine(message)}"

    fun singleLine(message: String): String =
        if (message.indexOf('\n') < 0 && message.indexOf('\r') < 0) message
        else message.replace("\r\n", "\\n").replace('\r', ' ').replace("\n", "\\n")
}

/** getLog() options (DESIGN.md: sinceMs 24 h ago, limit 1000, order 'asc'). */
data class LogQuery(val sinceMs: Long, val limit: Int, val ascending: Boolean) {
    companion object {
        const val DEFAULT_WINDOW_MS = 24 * 3_600_000L
        const val DEFAULT_LIMIT = 1000

        fun parse(options: JSONObject, nowMs: Long): LogQuery {
            val since = Json.value(options, "sinceMs")
            if (since != null && since !is Number) throw ConfigException("sinceMs", "must be a number")
            val limit = Json.value(options, "limit")
            if (limit != null && limit !is Number) throw ConfigException("limit", "must be a number")
            val order = Json.value(options, "order")
            if (order != null && order != "asc" && order != "desc") throw ConfigException("order", "must be 'asc' or 'desc'")
            return LogQuery(
                sinceMs = (since as Number?)?.toLong() ?: (nowMs - DEFAULT_WINDOW_MS),
                limit = ((limit as Number?)?.toInt() ?: DEFAULT_LIMIT).coerceIn(1, 100_000),
                ascending = order != "desc",
            )
        }
    }
}
