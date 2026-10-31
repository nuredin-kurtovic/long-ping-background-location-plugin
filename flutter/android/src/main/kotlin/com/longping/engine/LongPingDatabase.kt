package com.longping.engine

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** One SQLite file holds the upload queue and the on-device log. */
internal class LongPingDatabase(context: Context) : SQLiteOpenHelper(context, NAME, null, VERSION) {
    init {
        // The engine thread inserts while the upload thread reads and deletes; WAL keeps them from blocking each other.
        setWriteAheadLoggingEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE queue (id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT NOT NULL UNIQUE, " +
                "recorded_at INTEGER NOT NULL, json TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)",
        )
        db.execSQL("CREATE INDEX queue_recorded_at ON queue(recorded_at)")
        db.execSQL(
            "CREATE TABLE log (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, level TEXT NOT NULL, " +
                "tag TEXT NOT NULL, message TEXT NOT NULL)",
        )
        db.execSQL("CREATE INDEX log_ts ON log(ts)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    companion object {
        const val NAME = "longping.db"
        const val VERSION = 1
    }
}
