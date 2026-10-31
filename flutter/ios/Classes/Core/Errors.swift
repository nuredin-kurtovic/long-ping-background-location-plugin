import Foundation

/// Promise rejection codes (DESIGN.md, "Error codes").
enum ErrorCode: String {
    case invalidConfig = "INVALID_CONFIG"
    case permissionDenied = "PERMISSION_DENIED"
    case locationServicesOff = "LOCATION_SERVICES_OFF"
    case notEnabled = "NOT_ENABLED"
    case timeout = "TIMEOUT"
    case noActivity = "NO_ACTIVITY"
    case internalError = "INTERNAL"
}

struct LongPingError: Error, Equatable, CustomStringConvertible {
    let code: ErrorCode
    let message: String

    init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    var description: String { "\(code.rawValue): \(message)" }
}

/// A config problem. `key` is the dotted path the integrator wrote (e.g. `http.maxBatchSize`).
struct ConfigError: Error, Equatable, CustomStringConvertible {
    let key: String
    let reason: String

    var description: String { "\(key) \(reason)" }
    var asLongPingError: LongPingError { LongPingError(.invalidConfig, description) }
}
