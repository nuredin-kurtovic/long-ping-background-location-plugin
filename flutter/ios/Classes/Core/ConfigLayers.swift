import Foundation

/// The app's config and the server's overrides (DESIGN.md, "Remote config").
///
/// - `local`: the configure() / setConfig() result.
/// - `overrides`: every accepted `long_ping.config` deep-merged into one object, kept until `long_ping.reset`.
/// - `effective`: the overrides deep-merged onto `local` and validated together. While the app's `remoteConfig`
///   is false the overrides stay stored but are not applied.
struct ConfigLayers: Equatable {
    struct LocalChange: Equatable {
        var notes: [ConfigResolver.Note]
        /// Set when the overrides no longer validate on top of the new local config; they were cleared.
        var droppedOverrides: ConfigError?
    }

    struct RemoteChange: Equatable {
        /// `config` arrived while `remoteConfig` is false; it was not stored.
        var ignored = false
        /// `config` did not validate on top of the current config; it was not stored (a reset still applies).
        var rejected: ConfigError?
        /// The server sent `remoteConfig`; only the app sets it, so it was dropped from the overrides.
        var remoteConfigKeyIgnored = false
        var notes: [ConfigResolver.Note] = []
        var overridesChanged = false
        var effectiveChanged = false
    }

    private(set) var local: LongPingConfig
    private(set) var overrides: JSONObject
    private(set) var effective: LongPingConfig

    init(local: LongPingConfig = .defaults) {
        self.local = local
        overrides = JSONObject()
        effective = local
    }

    /// From storage. Overrides that do not validate on top of `local` are dropped; `dropped` says why.
    static func restore(local: LongPingConfig, overrides stored: JSONValue?) -> (layers: ConfigLayers, dropped: ConfigError?) {
        var layers = ConfigLayers(local: local)
        layers.overrides = stored?.objectValue ?? JSONObject()
        let dropped = layers.recompute()
        return (layers, dropped)
    }

    /// configure() (`merge` false: defaults + patch) or setConfig() (`merge` true: onto the app's current config).
    /// Throws only for the app's own input; overrides that stop validating on top of it are cleared instead.
    mutating func setLocal(_ patch: JSONValue, merge: Bool) throws -> LocalChange {
        let resolution = try ConfigResolver.resolve(patch, onto: merge ? local.json : LongPingConfig.defaults.json)
        local = resolution.config
        return LocalChange(notes: resolution.notes, droppedOverrides: recompute())
    }

    /// One `long_ping` reply: `reset` clears the overrides first, then `config` merges into them.
    mutating func applyRemote(config: JSONValue?, reset: Bool) -> RemoteChange {
        var change = RemoteChange()
        let previousOverrides = overrides
        let previousEffective = effective
        var next = reset ? JSONObject() : overrides
        if var patch = config?.objectValue {
            if !local.remoteConfig {
                change.ignored = true
            } else {
                if patch["remoteConfig"] != nil {
                    patch["remoteConfig"] = nil
                    change.remoteConfigKeyIgnored = true
                }
                let merged = JSONValue.object(next).deepMerged(with: .object(patch)).objectValue ?? next
                do {
                    change.notes = try ConfigResolver.resolve(.object(merged), onto: local.json).notes
                    next = merged
                } catch {
                    change.rejected = error as? ConfigError ?? ConfigError(key: "config", reason: "\(error)")
                }
            }
        }
        overrides = next
        // Cannot drop anything here: `next` is empty, unchanged or was just validated.
        _ = recompute()
        change.overridesChanged = overrides != previousOverrides
        change.effectiveChanged = effective != previousEffective
        return change
    }

    private mutating func recompute() -> ConfigError? {
        guard local.remoteConfig, !overrides.isEmpty else {
            effective = local
            return nil
        }
        do {
            effective = try ConfigResolver.resolve(.object(overrides), onto: local.json).config
            return nil
        } catch {
            overrides = JSONObject()
            effective = local
            return error as? ConfigError ?? ConfigError(key: "config", reason: "\(error)")
        }
    }
}
