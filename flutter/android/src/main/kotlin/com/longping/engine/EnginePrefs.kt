package com.longping.engine

import android.annotation.SuppressLint
import android.content.Context

/**
 * SharedPreferences `longping` (DESIGN.md): config, server overrides, engine state, upload pacing,
 * last location, flags, auth blob. Config, overrides, enabled flips and auth use commit(): they run
 * on engine threads (never the main thread) and must survive a process kill right after the call
 * returns.
 */
@SuppressLint("ApplySharedPref")
internal class EnginePrefs(context: Context) {
    private val sp = context.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    /** The app's layer (configure / setConfig); the server's overrides are stored apart. */
    val config: String? get() = sp.getString(KEY_CONFIG, null)
    val remoteOverrides: String? get() = sp.getString(KEY_REMOTE_OVERRIDES, null)
    val state: String? get() = sp.getString(KEY_STATE, null)
    val upload: String? get() = sp.getString(KEY_UPLOAD, null)
    val lastLocation: String? get() = sp.getString(KEY_LAST_LOCATION, null)
    val lastLocationAt: Long? get() = if (sp.contains(KEY_LAST_LOCATION_AT)) sp.getLong(KEY_LAST_LOCATION_AT, 0) else null
    val authBlob: String? get() = sp.getString(KEY_AUTH, null)

    /** Set at boot when tracking is enabled but startOnBoot is false; cleared when the app opens or start/stop runs. */
    var bootSuppressed: Boolean
        get() = sp.getBoolean(KEY_BOOT_SUPPRESSED, false)
        set(value) {
            if (value != bootSuppressed) sp.edit().putBoolean(KEY_BOOT_SUPPRESSED, value).commit()
        }

    var permissionAsked: Boolean
        get() = sp.getBoolean(KEY_PERMISSION_ASKED, false)
        set(value) {
            sp.edit().putBoolean(KEY_PERMISSION_ASKED, value).apply()
        }

    fun saveConfig(json: String) {
        sp.edit().putString(KEY_CONFIG, json).commit()
    }

    /** `{}` (no overrides) removes the key. */
    fun saveRemoteOverrides(json: String) {
        val editor = sp.edit()
        if (json == "{}") editor.remove(KEY_REMOTE_OVERRIDES) else editor.putString(KEY_REMOTE_OVERRIDES, json)
        editor.commit()
    }

    /** [durable]: commit synchronously (enabled flips must survive an immediate process kill). */
    fun saveState(json: String, durable: Boolean) {
        val editor = sp.edit().putString(KEY_STATE, json)
        if (durable) editor.commit() else editor.apply()
    }

    fun saveUpload(json: String) {
        sp.edit().putString(KEY_UPLOAD, json).apply()
    }

    fun saveLastLocation(json: String, atMs: Long) {
        sp.edit().putString(KEY_LAST_LOCATION, json).putLong(KEY_LAST_LOCATION_AT, atMs).apply()
    }

    fun saveAuthBlob(blob: String?) {
        val editor = sp.edit()
        if (blob == null) editor.remove(KEY_AUTH) else editor.putString(KEY_AUTH, blob)
        editor.commit()
    }

    companion object {
        const val NAME = "longping"
        const val KEY_CONFIG = "config"
        const val KEY_REMOTE_OVERRIDES = "remote_overrides"
        const val KEY_STATE = "state"
        const val KEY_UPLOAD = "upload"
        const val KEY_LAST_LOCATION = "last_location"
        const val KEY_LAST_LOCATION_AT = "last_location_at"
        const val KEY_PERMISSION_ASKED = "permission_asked"
        const val KEY_AUTH = "auth"
        const val KEY_BOOT_SUPPRESSED = "boot_suppressed"
    }
}
