import Foundation
import Security

/// Config, server overrides and engine state in the `com.longping` UserDefaults suite (DESIGN.md, "Config").
final class Preferences {
    static let suiteName = "com.longping"
    private static let configKey = "config"
    private static let remoteOverridesKey = "remoteOverrides"
    private static let stateKey = "state"
    private static let installMarkerKey = "installed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: Preferences.suiteName)) {
        self.defaults = defaults ?? .standard
    }

    func loadConfigJSON() -> JSONValue? {
        guard let text = defaults.string(forKey: Self.configKey) else { return nil }
        return try? JSONValue.parse(text)
    }

    /// The app's layer (configure() / setConfig()); the server's overrides are stored apart.
    func save(_ config: LongPingConfig) {
        defaults.set(config.json.serialized(), forKey: Self.configKey)
    }

    func loadRemoteOverrides() -> JSONValue? {
        guard let text = defaults.string(forKey: Self.remoteOverridesKey) else { return nil }
        return try? JSONValue.parse(text)
    }

    func saveRemoteOverrides(_ overrides: JSONObject) {
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.remoteOverridesKey)
        } else {
            defaults.set(JSONValue.object(overrides).serialized(), forKey: Self.remoteOverridesKey)
        }
    }

    func loadState() -> PersistedEngineState {
        guard let text = defaults.string(forKey: Self.stateKey), let json = try? JSONValue.parse(text) else {
            return PersistedEngineState()
        }
        return PersistedEngineState(json: json)
    }

    func save(_ state: PersistedEngineState) {
        defaults.set(state.json.serialized(), forKey: Self.stateKey)
    }

    /// False on the first launch after an install. Keychain items outlive an uninstall; UserDefaults do not.
    var isFirstLaunchAfterInstall: Bool { !defaults.bool(forKey: Self.installMarkerKey) }

    func markInstalled() { defaults.set(true, forKey: Self.installMarkerKey) }
}

/// Upload credentials in the Keychain (service `com.longping.auth`, accessible after first unlock).
final class KeychainAuthStore {
    static let service = "com.longping.auth"
    private static let account = "credentials"

    enum LoadResult {
        case found(AuthCredentials)
        case none
        /// Keychain locked (before the first unlock after a reboot): try again later.
        case unavailable(OSStatus)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() -> LoadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let json = try? JSONValue.parse(data: data),
                  let credentials = try? AuthCredentials(json: json) else { return .none }
            return .found(credentials)
        case errSecItemNotFound:
            return .none
        default:
            return .unavailable(status)
        }
    }

    @discardableResult
    func save(_ credentials: AuthCredentials) -> OSStatus {
        let data = credentials.json.data
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = baseQuery
        add.merge(update) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult
    func delete() -> OSStatus {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// io-queue cache in front of the Keychain so every upload does not hit SecItemCopyMatching.
final class AuthCache {
    private let keychain: KeychainAuthStore
    private let logger: EngineLogger
    private var loaded = false
    private var cached: AuthCredentials?
    /// True while the Keychain refuses reads (device not unlocked since boot). Uploads wait for it.
    private(set) var isLocked = false

    init(keychain: KeychainAuthStore, logger: EngineLogger) {
        self.keychain = keychain
        self.logger = logger
    }

    var current: AuthCredentials? {
        if !loaded {
            switch keychain.load() {
            case .found(let credentials):
                cached = credentials
                loaded = true
                isLocked = false
            case .none:
                cached = nil
                loaded = true
                isLocked = false
            case .unavailable(let status):
                if !isLocked { logger.warn("auth", "keychain unavailable (\(status)); uploads wait until the device is unlocked") }
                isLocked = true
            }
        }
        return cached
    }

    @discardableResult
    func store(_ credentials: AuthCredentials) -> Bool {
        cached = credentials
        loaded = true
        isLocked = false
        let status = keychain.save(credentials)
        if status != errSecSuccess {
            logger.error("auth", "keychain write failed (\(status)); credentials kept in memory for this run")
            return false
        }
        return true
    }

    func clear() {
        cached = nil
        loaded = true
        isLocked = false
        let status = keychain.delete()
        if status != errSecSuccess { logger.error("auth", "keychain delete failed (\(status))") }
    }
}
