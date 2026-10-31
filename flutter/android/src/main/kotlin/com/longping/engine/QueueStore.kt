package com.longping.engine

import android.content.ContentValues
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase

/** DESIGN.md, "Upload": queue rows, oldest first. */
internal class QueueStore(private val helper: LongPingDatabase) {
    data class Row(val id: Long, val uuid: String, val json: String, val attempts: Int)
    data class Pruned(val overLimit: Int, val expired: Int) {
        val total: Int get() = overLimit + expired
    }

    fun insert(uuid: String, recordedAtMs: Long, json: String) {
        val values = ContentValues().apply {
            put("uuid", uuid)
            put("recorded_at", recordedAtMs)
            put("json", json)
            put("attempts", 0)
        }
        helper.writableDatabase.insertWithOnConflict("queue", null, values, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun prune(maxRecords: Int, olderThanMs: Long): Pruned {
        val db = helper.writableDatabase
        val expired = db.delete("queue", "recorded_at < ?", arrayOf(olderThanMs.toString()))
        val excess = DatabaseUtils.queryNumEntries(db, "queue") - maxRecords
        val overLimit = if (excess > 0) {
            db.delete("queue", "id IN (SELECT id FROM queue ORDER BY id ASC LIMIT $excess)", null)
        } else {
            0
        }
        return Pruned(overLimit, expired)
    }

    fun oldest(limit: Int): List<Row> {
        val rows = ArrayList<Row>(limit)
        helper.readableDatabase.query("queue", arrayOf("id", "uuid", "json", "attempts"), null, null, null, null, "id ASC", limit.toString())
            .use { c ->
                while (c.moveToNext()) rows.add(Row(c.getLong(0), c.getString(1), c.getString(2), c.getInt(3)))
            }
        return rows
    }

    // Ids come from this table (Longs), so inlining them is safe and avoids SQLite's 999-variable limit on old devices.
    fun delete(ids: List<Long>): Int =
        if (ids.isEmpty()) 0 else helper.writableDatabase.delete("queue", "id IN (${ids.joinToString(",")})", null)

    fun incrementAttempts(ids: List<Long>) {
        if (ids.isNotEmpty()) helper.writableDatabase.execSQL("UPDATE queue SET attempts = attempts + 1 WHERE id IN (${ids.joinToString(",")})")
    }

    /** Deletes rows that reached [maxAttempts]; returns their uuids for the log. */
    fun dropExhausted(maxAttempts: Int): List<String> {
        val db = helper.writableDatabase
        val uuids = ArrayList<String>()
        db.query("queue", arrayOf("uuid"), "attempts >= ?", arrayOf(maxAttempts.toString()), null, null, null).use { c ->
            while (c.moveToNext()) uuids.add(c.getString(0))
        }
        if (uuids.isNotEmpty()) db.delete("queue", "attempts >= ?", arrayOf(maxAttempts.toString()))
        return uuids
    }

    fun count(): Long = DatabaseUtils.queryNumEntries(helper.readableDatabase, "queue")

    /** recorded_at of the newest queued record; null when the queue is empty. */
    fun newestRecordedAt(): Long? =
        helper.readableDatabase.rawQuery("SELECT MAX(recorded_at) FROM queue", null).use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
        }

    fun clear(): Int = helper.writableDatabase.delete("queue", null, null)
}
