import Foundation

/// Milliseconds since 1970-01-01T00:00:00Z. Every time value in Core uses this unit.
typealias EpochMs = Int64

/// Injected everywhere a decision depends on "now", so tests control time.
protocol TimeSource {
    var nowMs: EpochMs { get }
}

struct SystemClock: TimeSource {
    var nowMs: EpochMs { EpochMs((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

extension EpochMs {
    static let minuteMs: EpochMs = 60_000
    static let dayMs: EpochMs = 86_400_000
    /// Upper bound for timestamps read from storage or JS (year 5000).
    static let latestPlausible: EpochMs = 95_617_584_000_000

    /// Saturating conversion. `Int64(Double)` traps on NaN, infinity and overflow; values that reach us
    /// from JS or from storage must never crash the host app.
    init(clamping value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= 9.2e18 {
            self = .max
        } else if value <= -9.2e18 {
            self = .min
        } else {
            self = EpochMs(value)
        }
    }

    init(seconds: Double) { self.init(clamping: (seconds * 1000).rounded()) }

    /// A stored or supplied epoch-ms value, or nil when it is not a plausible wall-clock time.
    static func timestamp(_ value: Double?) -> EpochMs? {
        guard let value, value.isFinite, value >= 0, value <= Double(latestPlausible) else { return nil }
        return EpochMs(value)
    }
}

enum Timestamp {
    /// `2026-10-26T12:00:00.123Z` — UTC, millisecond precision, the record and log format.
    static func iso8601(_ ms: EpochMs) -> String {
        var seconds = ms / 1000
        var millis = ms % 1000
        if millis < 0 {
            millis += 1000
            seconds -= 1
        }
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
            Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), Int(millis)
        )
    }
}
