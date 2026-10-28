import Foundation

enum Accuracy: String, CaseIterable {
    case high, balanced, low
}

enum HTTPMethod: String, CaseIterable {
    case post = "POST"
    case put = "PUT"
}

enum ActivityType: String, CaseIterable {
    case automotive, otherNavigation, fitness, other
}

enum NotificationPriority: String, CaseIterable {
    case low, `default`, high
}

enum LogLevel: String, CaseIterable, Comparable {
    case off, error, warn, info, debug

    /// Higher = more verbose. `off` writes nothing.
    var verbosity: Int {
        switch self {
        case .off: return 0
        case .error: return 1
        case .warn: return 2
        case .info: return 3
        case .debug: return 4
        }
    }

    /// Whether a message at `level` passes this threshold.
    func allows(_ level: LogLevel) -> Bool {
        level != .off && level.verbosity <= verbosity
    }

    /// The 5-wide label used in log lines.
    var label: String {
        switch self {
        case .off: return "OFF  "
        case .error: return "ERROR"
        case .warn: return "WARN "
        case .info: return "INFO "
        case .debug: return "DEBUG"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.verbosity < rhs.verbosity }
}

struct LowBatteryPolicy: Equatable {
    var belowPct: Double
    var intervalSec: Double
}

struct HTTPConfig: Equatable {
    var url: String?
    var method: HTTPMethod = .post
    var headers: [String: String] = [:]
    var batch = true
    var maxBatchSize = 100
    var uploadIntervalSec: Double = 0
    var rootProperty: String?
    var locationTemplate: String?
    var params = JSONObject()
    var extras = JSONObject()
    var timeoutSec: Double = 30

    /// nil = record only, never upload.
    var uploadURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url)
    }
}

struct PersistenceConfig: Equatable {
    var maxRecords = 10_000
    var maxDays = 7
}

struct NotificationConfig: Equatable {
    var title = "Location tracking"
    var text = "Sharing your location"
    var channelName = "Location tracking"
    var smallIcon: String?
    var priority: NotificationPriority = .low
}

struct IOSConfig: Equatable {
    var showsBackgroundLocationIndicator = false
    var activityType: ActivityType = .automotive
}

/// The fully resolved config (every key filled in). Field names and defaults mirror DESIGN.md.
struct LongPingConfig: Equatable {
    var licenseKey: String?
    var movingIntervalSec: Double = 30
    var parkedIntervalSec: Double = 180
    var accuracy: Accuracy = .high
    var minAccuracyM: Double = 100
    var stopTimeoutSec: Double = 300
    var stopRadiusM: Double = 75
    var movingSpeedMps: Double = 3
    var disableStopDetection = false
    var lowBattery: LowBatteryPolicy?
    var http = HTTPConfig()
    var persistence = PersistenceConfig()
    var startOnBoot = true
    var stopOnTerminate = false
    var remoteConfig = true
    var notification = NotificationConfig()
    var ios = IOSConfig()
    var logLevel: LogLevel = .info
    var logMaxDays = 3
    var debug = false

    static let defaults = LongPingConfig()

    /// Full JSON in DESIGN.md key order: persisted, returned in State.config and `configchange`.
    var json: JSONValue {
        var http = JSONObject()
        http["url"] = self.http.url.map(JSONValue.string) ?? .null
        http["method"] = .string(self.http.method.rawValue)
        var headers = JSONObject()
        for key in self.http.headers.keys.sorted() { headers[key] = .string(self.http.headers[key] ?? "") }
        http["headers"] = .object(headers)
        http["batch"] = .bool(self.http.batch)
        http["maxBatchSize"] = .number(Double(self.http.maxBatchSize))
        http["uploadIntervalSec"] = .number(self.http.uploadIntervalSec)
        http["rootProperty"] = self.http.rootProperty.map(JSONValue.string) ?? .null
        http["locationTemplate"] = self.http.locationTemplate.map(JSONValue.string) ?? .null
        http["params"] = .object(self.http.params)
        http["extras"] = .object(self.http.extras)
        http["timeoutSec"] = .number(self.http.timeoutSec)

        var root = JSONObject()
        root["licenseKey"] = licenseKey.map(JSONValue.string) ?? .null
        root["movingIntervalSec"] = .number(movingIntervalSec)
        root["parkedIntervalSec"] = .number(parkedIntervalSec)
        root["accuracy"] = .string(accuracy.rawValue)
        root["minAccuracyM"] = .number(minAccuracyM)
        root["stopTimeoutSec"] = .number(stopTimeoutSec)
        root["stopRadiusM"] = .number(stopRadiusM)
        root["movingSpeedMps"] = .number(movingSpeedMps)
        root["disableStopDetection"] = .bool(disableStopDetection)
        root["lowBattery"] = lowBattery.map {
            .object(JSONObject([("belowPct", .number($0.belowPct)), ("intervalSec", .number($0.intervalSec))]))
        } ?? .null
        root["http"] = .object(http)
        root["persistence"] = .object(JSONObject([
            ("maxRecords", .number(Double(persistence.maxRecords))),
            ("maxDays", .number(Double(persistence.maxDays))),
        ]))
        root["startOnBoot"] = .bool(startOnBoot)
        root["stopOnTerminate"] = .bool(stopOnTerminate)
        root["remoteConfig"] = .bool(remoteConfig)
        root["notification"] = .object(JSONObject([
            ("title", .string(notification.title)),
            ("text", .string(notification.text)),
            ("channelName", .string(notification.channelName)),
            ("smallIcon", notification.smallIcon.map(JSONValue.string) ?? .null),
            ("priority", .string(notification.priority.rawValue)),
        ]))
        root["ios"] = .object(JSONObject([
            ("showsBackgroundLocationIndicator", .bool(ios.showsBackgroundLocationIndicator)),
            ("activityType", .string(ios.activityType.rawValue)),
        ]))
        root["logLevel"] = .string(logLevel.rawValue)
        root["logMaxDays"] = .number(Double(logMaxDays))
        root["debug"] = .bool(debug)
        return .object(root)
    }
}
