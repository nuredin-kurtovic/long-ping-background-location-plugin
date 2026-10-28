import Foundation

/// Turns integrator input into a `LongPingConfig`.
///
/// - `configure(x)`  = `resolve(x)` (defaults + x)
/// - `setConfig(x)`  = `resolve(x, onto: current.json)` (deep merge: objects merge, arrays/scalars replace)
///
/// Wrong types and bad enum values throw a `ConfigError` naming the key. Out-of-range numbers are clamped
/// and reported in `notes`, as are unknown keys (which are ignored). `null` on a key that is not nullable
/// resets that key to its default.
enum ConfigResolver {
    struct Resolution: Equatable {
        var config: LongPingConfig
        /// Human-readable remarks for the log: unknown keys and clamped values.
        var notes: [Note]
    }

    struct Note: Equatable, CustomStringConvertible {
        enum Kind: Equatable { case unknownKey, clamped, adjusted }
        let kind: Kind
        let message: String
        var description: String { message }
    }

    static func resolve(_ patch: JSONValue, onto base: JSONValue = LongPingConfig.defaults.json) throws -> Resolution {
        let input: JSONValue
        switch patch {
        case .null: input = .object(JSONObject())
        case .object: input = patch
        default: throw ConfigError(key: "config", reason: "must be an object")
        }
        let merged = base.deepMerged(with: input)
        var decoder = Decoder()
        let config = try decoder.decode(merged.objectValue ?? JSONObject())
        var notes = unknownKeys(in: input).map { Note(kind: .unknownKey, message: "unknown key '\($0)' ignored") }
        notes.append(contentsOf: decoder.notes)
        return Resolution(config: config, notes: notes)
    }

    // MARK: - Unknown keys

    private static let topLevelKeys: Set<String> = [
        "licenseKey", "movingIntervalSec", "parkedIntervalSec", "accuracy", "minAccuracyM", "stopTimeoutSec",
        "stopRadiusM", "movingSpeedMps", "disableStopDetection", "lowBattery", "http", "persistence",
        "startOnBoot", "stopOnTerminate", "remoteConfig", "notification", "ios", "logLevel", "logMaxDays", "debug",
    ]

    /// Nested objects with a fixed shape. headers/params/extras are free-form and not checked.
    private static let nestedKeys: [String: Set<String>] = [
        "lowBattery": ["belowPct", "intervalSec"],
        "http": ["url", "method", "headers", "batch", "maxBatchSize", "uploadIntervalSec", "rootProperty",
                 "locationTemplate", "params", "extras", "timeoutSec"],
        "persistence": ["maxRecords", "maxDays"],
        "notification": ["title", "text", "channelName", "smallIcon", "priority"],
        "ios": ["showsBackgroundLocationIndicator", "activityType"],
    ]

    static func unknownKeys(in input: JSONValue) -> [String] {
        guard let object = input.objectValue else { return [] }
        var unknown: [String] = []
        for (key, value) in object {
            guard topLevelKeys.contains(key) else { unknown.append(key); continue }
            if let allowed = nestedKeys[key], let nested = value.objectValue {
                unknown.append(contentsOf: nested.keys.filter { !allowed.contains($0) }.map { "\(key).\($0)" })
            }
        }
        return unknown
    }

    // MARK: - Decoding

    private struct Decoder {
        var notes: [Note] = []

        mutating func decode(_ root: JSONObject) throws -> LongPingConfig {
            let d = LongPingConfig.defaults
            var c = LongPingConfig()
            c.licenseKey = try optionalString(root, "licenseKey", path: "")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            c.movingIntervalSec = try number(root, "movingIntervalSec", path: "", default: d.movingIntervalSec, clamp: 1...86_400)
            c.parkedIntervalSec = try number(root, "parkedIntervalSec", path: "", default: d.parkedIntervalSec, clamp: 1...86_400)
            c.accuracy = try enumeration(root, "accuracy", path: "", default: d.accuracy)
            c.minAccuracyM = try number(root, "minAccuracyM", path: "", default: d.minAccuracyM, clamp: 0...Double.greatestFiniteMagnitude)
            c.stopTimeoutSec = try number(root, "stopTimeoutSec", path: "", default: d.stopTimeoutSec, clamp: 30...86_400)
            c.stopRadiusM = try number(root, "stopRadiusM", path: "", default: d.stopRadiusM, clamp: 10...10_000)
            c.movingSpeedMps = try number(root, "movingSpeedMps", path: "", default: d.movingSpeedMps, clamp: 0.5...100)
            c.disableStopDetection = try bool(root, "disableStopDetection", path: "", default: d.disableStopDetection)
            c.lowBattery = try lowBattery(root)
            c.http = try http(try objectField(root, "http", path: ""))
            let persistence = try objectField(root, "persistence", path: "")
            c.persistence.maxRecords = try integer(persistence, "maxRecords", path: "persistence", default: d.persistence.maxRecords, clamp: 1...1_000_000)
            c.persistence.maxDays = try integer(persistence, "maxDays", path: "persistence", default: d.persistence.maxDays, clamp: 1...365)
            c.startOnBoot = try bool(root, "startOnBoot", path: "", default: d.startOnBoot)
            c.stopOnTerminate = try bool(root, "stopOnTerminate", path: "", default: d.stopOnTerminate)
            c.remoteConfig = try bool(root, "remoteConfig", path: "", default: d.remoteConfig)
            let notification = try objectField(root, "notification", path: "")
            c.notification.title = try string(notification, "title", path: "notification", default: d.notification.title)
            c.notification.text = try string(notification, "text", path: "notification", default: d.notification.text)
            c.notification.channelName = try string(notification, "channelName", path: "notification", default: d.notification.channelName)
            c.notification.smallIcon = try optionalString(notification, "smallIcon", path: "notification").flatMap { $0.isEmpty ? nil : $0 }
            c.notification.priority = try enumeration(notification, "priority", path: "notification", default: d.notification.priority)
            let ios = try objectField(root, "ios", path: "")
            c.ios.showsBackgroundLocationIndicator = try bool(ios, "showsBackgroundLocationIndicator", path: "ios", default: d.ios.showsBackgroundLocationIndicator)
            c.ios.activityType = try enumeration(ios, "activityType", path: "ios", default: d.ios.activityType)
            c.logLevel = try enumeration(root, "logLevel", path: "", default: d.logLevel)
            c.logMaxDays = try integer(root, "logMaxDays", path: "", default: d.logMaxDays, clamp: 1...30)
            c.debug = try bool(root, "debug", path: "", default: d.debug)
            return c
        }

        private mutating func lowBattery(_ root: JSONObject) throws -> LowBatteryPolicy? {
            guard let value = root["lowBattery"], !value.isNull else { return nil }
            guard let object = value.objectValue else { throw ConfigError(key: "lowBattery", reason: "must be an object or null") }
            for field in ["belowPct", "intervalSec"] where object[field] == nil || object[field] == .null {
                throw ConfigError(key: "lowBattery.\(field)", reason: "is required")
            }
            return LowBatteryPolicy(
                belowPct: try number(object, "belowPct", path: "lowBattery", default: 0, clamp: 0...100),
                intervalSec: try number(object, "intervalSec", path: "lowBattery", default: 0, clamp: 1...86_400)
            )
        }

        private mutating func http(_ object: JSONObject) throws -> HTTPConfig {
            let d = HTTPConfig()
            var h = HTTPConfig()
            let path = "http"
            h.url = try optionalString(object, "url", path: path).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            if let url = h.url {
                guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", parsed.host != nil else {
                    throw ConfigError(key: "http.url", reason: "must be an http(s) URL or null")
                }
            }
            h.method = try enumeration(object, "method", path: path, default: d.method)
            h.headers = try stringMap(object, "headers", path: path)
            h.batch = try bool(object, "batch", path: path, default: d.batch)
            h.maxBatchSize = try integer(object, "maxBatchSize", path: path, default: d.maxBatchSize, clamp: 1...1000)
            h.uploadIntervalSec = try number(object, "uploadIntervalSec", path: path, default: d.uploadIntervalSec, clamp: 0...86_400)
            h.rootProperty = try optionalString(object, "rootProperty", path: path).flatMap { $0.isEmpty ? nil : $0 }
            if h.rootProperty == ".", h.batch {
                notes.append(Note(kind: .adjusted, message: "http.rootProperty '.' only applies to single uploads; batches use 'locations'"))
            }
            h.params = try objectField(object, "params", path: path)
            h.extras = try objectField(object, "extras", path: path)
            h.timeoutSec = try number(object, "timeoutSec", path: path, default: d.timeoutSec, clamp: 5...120)
            h.locationTemplate = try optionalString(object, "locationTemplate", path: path).flatMap { $0.isEmpty ? nil : $0 }
            if let template = h.locationTemplate {
                try LocationTemplate.validate(template, extras: h.extras)
            }
            return h
        }

        // MARK: Field readers

        private func key(_ name: String, _ path: String) -> String { path.isEmpty ? name : "\(path).\(name)" }

        /// nil for absent or explicit null (both mean "use the default").
        private func present(_ object: JSONObject, _ name: String) -> JSONValue? {
            guard let value = object[name], !value.isNull else { return nil }
            return value
        }

        private mutating func number(_ object: JSONObject, _ name: String, path: String, default fallback: Double,
                                     clamp range: ClosedRange<Double>) throws -> Double {
            guard let value = present(object, name) else { return fallback }
            guard let n = value.numberValue, n.isFinite else {
                throw ConfigError(key: key(name, path), reason: "must be a number")
            }
            let clamped = min(max(n, range.lowerBound), range.upperBound)
            if clamped != n {
                notes.append(Note(kind: .clamped, message: "\(key(name, path)) \(JSONValue.format(n)) out of range, using \(JSONValue.format(clamped))"))
            }
            return clamped
        }

        private mutating func integer(_ object: JSONObject, _ name: String, path: String, default fallback: Int,
                                      clamp range: ClosedRange<Int>) throws -> Int {
            let n = try number(object, name, path: path, default: Double(fallback),
                               clamp: Double(range.lowerBound)...Double(range.upperBound))
            return Int(n.rounded())
        }

        private func bool(_ object: JSONObject, _ name: String, path: String, default fallback: Bool) throws -> Bool {
            guard let value = present(object, name) else { return fallback }
            guard let b = value.boolValue else { throw ConfigError(key: key(name, path), reason: "must be a boolean") }
            return b
        }

        private func string(_ object: JSONObject, _ name: String, path: String, default fallback: String) throws -> String {
            guard let value = present(object, name) else { return fallback }
            guard let s = value.stringValue else { throw ConfigError(key: key(name, path), reason: "must be a string") }
            return s
        }

        private func optionalString(_ object: JSONObject, _ name: String, path: String) throws -> String? {
            guard let value = present(object, name) else { return nil }
            guard let s = value.stringValue else { throw ConfigError(key: key(name, path), reason: "must be a string or null") }
            return s
        }

        private func enumeration<E: RawRepresentable & CaseIterable>(_ object: JSONObject, _ name: String, path: String,
                                                                     default fallback: E) throws -> E where E.RawValue == String {
            guard let value = present(object, name) else { return fallback }
            guard let raw = value.stringValue, let e = E(rawValue: raw) else {
                let allowed = E.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
                throw ConfigError(key: key(name, path), reason: "must be one of \(allowed)")
            }
            return e
        }

        private func objectField(_ object: JSONObject, _ name: String, path: String) throws -> JSONObject {
            guard let value = present(object, name) else { return JSONObject() }
            guard let o = value.objectValue else { throw ConfigError(key: key(name, path), reason: "must be an object") }
            return o
        }

        private func stringMap(_ object: JSONObject, _ name: String, path: String) throws -> [String: String] {
            var result: [String: String] = [:]
            for (k, v) in try objectField(object, name, path: path) {
                guard let s = v.stringValue else {
                    throw ConfigError(key: "\(key(name, path)).\(k)", reason: "must be a string")
                }
                result[k] = s
            }
            return result
        }
    }
}
