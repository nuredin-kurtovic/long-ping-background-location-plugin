import Foundation

/// Engine state that survives app kills (DESIGN.md, "Lifecycle and recovery": enabled, isMoving, anchor,
/// parkedAt, lastRecordedTime, lastFixTime) plus what `getState()` needs after a relaunch.
struct PersistedEngineState: Equatable {
    var enabled = false
    var isMoving = false
    var anchor: Fix?
    var parkedAt: Fix?
    var lastRecordedTime: EpochMs?
    var lastFixTime: EpochMs?
    /// The last recorded location record (State.lastLocation).
    var lastLocation: JSONValue?
    var authorizationRequired = false

    var lastLocationAt: EpochMs? {
        guard let ts = lastLocation?["timestamp"]?.stringValue else { return nil }
        return Timestamp.parseISO8601(ts)
    }

    var json: JSONValue {
        func ms(_ v: EpochMs?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }
        return .object(JSONObject([
            ("enabled", .bool(enabled)),
            ("isMoving", .bool(isMoving)),
            ("anchor", anchor?.json ?? .null),
            ("parkedAt", parkedAt?.json ?? .null),
            ("lastRecordedTime", ms(lastRecordedTime)),
            ("lastFixTime", ms(lastFixTime)),
            ("lastLocation", lastLocation ?? .null),
            ("authorizationRequired", .bool(authorizationRequired)),
        ]))
    }

    init() {}

    /// Lenient: anything unreadable falls back to the default for that field.
    init(json: JSONValue) {
        enabled = json["enabled"]?.boolValue ?? false
        isMoving = json["isMoving"]?.boolValue ?? false
        anchor = json["anchor"].flatMap(Fix.init(json:))
        parkedAt = json["parkedAt"].flatMap(Fix.init(json:))
        lastRecordedTime = EpochMs.timestamp(json["lastRecordedTime"]?.numberValue)
        lastFixTime = EpochMs.timestamp(json["lastFixTime"]?.numberValue)
        lastLocation = json["lastLocation"].flatMap { $0.objectValue != nil ? $0 : nil }
        authorizationRequired = json["authorizationRequired"]?.boolValue ?? false
    }
}

extension Timestamp {
    /// Inverse of `iso8601(_:)` for the exact format we write. nil for anything else.
    static func parseISO8601(_ s: String) -> EpochMs? {
        let c = Array(s.utf8)
        guard c.count == 24, c[4] == 0x2D, c[7] == 0x2D, c[10] == 0x54, c[13] == 0x3A, c[16] == 0x3A,
              c[19] == 0x2E, c[23] == 0x5A else { return nil }
        func num(_ range: Range<Int>) -> Int? {
            var v = 0
            for i in range {
                guard c[i] >= 0x30, c[i] <= 0x39 else { return nil }
                v = v * 10 + Int(c[i] - 0x30)
            }
            return v
        }
        guard let year = num(0..<4), let month = num(5..<7), let day = num(8..<10), let hour = num(11..<13),
              let minute = num(14..<16), let second = num(17..<19), let millis = num(20..<23),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        // Days from civil (Howard Hinnant), avoiding Calendar/TimeZone state.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second)
        return seconds * 1000 + Int64(millis)
    }
}
