package com.longping.core

import org.json.JSONObject

/**
 * The app's config and the server's overrides (DESIGN.md, "Remote config").
 *
 * - [local]: the configure() / setConfig() result.
 * - overrides: every accepted `long_ping.config` deep-merged into one object, kept until `long_ping.reset`.
 * - [effective]: the overrides deep-merged onto [local] and validated together. While the app's
 *   `remoteConfig` is false the overrides stay stored but are not applied.
 */
class ConfigLayers private constructor(local: LongPingConfig, private var overrides: JSONObject) {
    /** [droppedOverrides]: the overrides no longer validate on top of the new local config; they were cleared. */
    class LocalChange(val unknownKeys: List<String>, val droppedOverrides: ConfigException?)

    class RemoteChange(
        /** `config` arrived while `remoteConfig` is false; it was not stored. */
        val ignored: Boolean,
        /** `config` did not validate on top of the current config; it was not stored (a reset still applies). */
        val rejected: ConfigException?,
        /** The server sent `remoteConfig`; only the app sets it, so it was dropped from the overrides. */
        val remoteConfigKeyIgnored: Boolean,
        val unknownKeys: List<String>,
        val overridesChanged: Boolean,
        val effectiveChanged: Boolean,
    )

    class Restored(val layers: ConfigLayers, val droppedOverrides: ConfigException?)

    var local: LongPingConfig = local
        private set

    var effective: LongPingConfig = local
        private set

    /** Stored form of the overrides; `{}` = none. */
    val overridesJson: String get() = overrides.toString()

    constructor(local: LongPingConfig = ConfigResolver.defaults()) : this(local, JSONObject())

    /**
     * configure() ([merge] false: defaults + input) or setConfig() ([merge] true: onto the app's
     * current config). Throws only for the app's own input; overrides that stop validating on top
     * of it are cleared instead.
     */
    fun setLocal(input: JSONObject, merge: Boolean): LocalChange {
        val r = if (merge) ConfigResolver.merge(local, input) else ConfigResolver.resolve(input)
        local = r.config
        return LocalChange(r.unknownKeys, recompute())
    }

    /** One `long_ping` reply: [reset] clears the overrides first, then [config] merges into them. */
    fun applyRemote(config: JSONObject?, reset: Boolean): RemoteChange {
        val previousOverrides = overrides.toString()
        val previousEffective = effective
        var next = if (reset) JSONObject() else overrides
        var ignored = false
        var rejected: ConfigException? = null
        var remoteConfigKeyIgnored = false
        var unknownKeys = emptyList<String>()
        if (config != null) {
            if (!local.remoteConfig) {
                ignored = true
            } else {
                val patch = Json.copy(config)
                if (patch.has("remoteConfig")) {
                    patch.remove("remoteConfig")
                    remoteConfigKeyIgnored = true
                }
                val merged = Json.deepMerge(next, patch)
                try {
                    unknownKeys = ConfigResolver.merge(local, merged).unknownKeys
                    next = merged
                } catch (e: ConfigException) {
                    rejected = e
                }
            }
        }
        overrides = next
        // Cannot drop anything here: `next` is empty, unchanged or was just validated.
        recompute()
        return RemoteChange(
            ignored = ignored,
            rejected = rejected,
            remoteConfigKeyIgnored = remoteConfigKeyIgnored,
            unknownKeys = unknownKeys,
            overridesChanged = overrides.toString() != previousOverrides,
            effectiveChanged = effective != previousEffective,
        )
    }

    private fun recompute(): ConfigException? {
        if (!local.remoteConfig || overrides.length() == 0) {
            effective = local
            return null
        }
        return try {
            effective = ConfigResolver.merge(local, overrides).config
            null
        } catch (e: ConfigException) {
            overrides = JSONObject()
            effective = local
            e
        }
    }

    companion object {
        /** From storage. Overrides that do not validate on top of [local] are dropped; [Restored.droppedOverrides] says why. */
        fun restore(local: LongPingConfig, storedOverrides: String?): Restored {
            val overrides = try {
                storedOverrides?.let { JSONObject(it) }
            } catch (e: Exception) {
                null
            }
            val layers = ConfigLayers(local, overrides ?: JSONObject())
            return Restored(layers, layers.recompute())
        }
    }
}
