package com.longping.engine

import android.content.ContentValues
import com.longping.core.LogFormat
import com.longping.core.LogLevel
import com.longping.core.LogQuery

/** DESIGN.md, getLog(): one formatted entry per line. */
internal class LogStore(private val helper: LongPingDatabase) {
    fun insert(ts: Long, level: LogLevel, tag: String, message: String) {
        val values = ContentValues().apply {
            put("ts", ts)
            put("level", level.label)
            put("tag", tag)
            put("message", message)
        }
        helper.writableDatabase.insert("log", null, values)
    }

    /** The newest [LogQuery.limit] entries since [LogQuery.sinceMs], returned in the requested order. */
    fun query(q: LogQuery): String {
        val lines = ArrayList<String>()
        helper.readableDatabase.query(
            "log", arrayOf("ts", "level", "tag", "message"), "ts >= ?", arrayOf(q.sinceMs.toString()),
            null, null, "id DESC", q.limit.toString(),
        ).use { c ->
            while (c.moveToNext()) {
                val level = LogLevel.entries.firstOrNull { it.label == c.getString(1) } ?: LogLevel.INFO
                lines.add(LogFormat.line(c.getLong(0), level, c.getString(2), c.getString(3)))
            }
        }
        if (q.ascending) lines.reverse()
        return lines.joinToString("\n")
    }

    fun prune(olderThanMs: Long): Int = helper.writableDatabase.delete("log", "ts < ?", arrayOf(olderThanMs.toString()))

    fun clear(): Int = helper.writableDatabase.delete("log", null, null)
}
