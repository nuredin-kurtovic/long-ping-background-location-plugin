import Foundation

/// `getCurrentPosition(opts)` options. Lenient: wrong types fall back to defaults, since these are
/// per-call request options rather than stored config.
struct CurrentPositionOptions: Equatable {
    var timeoutSec = 30.0
    var maximumAgeSec = 0.0
    /// nil = the configured accuracy.
    var accuracy: Accuracy?
    var persist = false
    var extras = JSONObject()

    init() {}

    init(_ json: JSONValue?) {
        guard let o = json?.objectValue else { return }
        if let v = o["timeoutSec"]?.numberValue, v.isFinite { timeoutSec = min(max(v, 1), 600) }
        if let v = o["maximumAgeSec"]?.numberValue, v.isFinite { maximumAgeSec = max(0, v) }
        if let v = o["accuracy"]?.stringValue { accuracy = Accuracy(rawValue: v) }
        if let v = o["persist"]?.boolValue { persist = v }
        if let v = o["extras"]?.objectValue { extras = v }
    }
}

/// The decisions behind one `getCurrentPosition` request.
enum CurrentPositionPolicy {
    /// On timeout, a last known fix younger than this is still returned.
    static let lastKnownMaxAgeMs: EpochMs = 600_000
    /// Clock skew allowance for fixes stamped just before the request started.
    static let startSlackMs: EpochMs = 2_000

    /// A fix at least this accurate resolves the request immediately.
    static func targetAccuracyM(_ accuracy: Accuracy) -> Double {
        switch accuracy {
        case .high: return 20
        case .balanced: return 100
        case .low: return 1000
        }
    }

    /// CoreLocation hands out its cached fix first; only fixes from the request window count, unless
    /// `maximumAgeSec` allows older ones.
    static func accepts(_ fix: Fix, startedAt: EpochMs, maximumAgeSec: Double) -> Bool {
        fix.time >= startedAt - max(EpochMs(seconds: maximumAgeSec), startSlackMs)
    }

    /// A known fix that satisfies `maximumAgeSec` without waiting (0 = always wait for a new one).
    static func cachedFix(_ known: Fix?, now: EpochMs, maximumAgeSec: Double) -> Fix? {
        guard maximumAgeSec > 0, let known, now - known.time <= EpochMs(seconds: maximumAgeSec) else { return nil }
        return known
    }

    /// Timeout: the best fix seen in the window, else the last known fix if younger than 10 min, else nil (TIMEOUT).
    static func onTimeout(best: Fix?, lastKnown: Fix?, now: EpochMs) -> Fix? {
        if let best { return best }
        guard let lastKnown, now - lastKnown.time < lastKnownMaxAgeMs else { return nil }
        return lastKnown
    }

    /// The newest of several candidate fixes.
    static func freshest(_ fixes: [Fix?]) -> Fix? {
        fixes.compactMap { $0 }.max { $0.time < $1.time }
    }
}

/// `getLog(opts)`: sinceMs (24 h ago), limit (1000), order ('asc').
struct LogQuery: Equatable {
    static let maxLimit = 100_000

    var sinceMs: EpochMs
    var limit: Int
    var ascending: Bool

    init(_ json: JSONValue?, now: EpochMs) {
        sinceMs = json?["sinceMs"]?.numberValue.flatMap { $0.isNaN ? nil : EpochMs(clamping: $0) } ?? now - .dayMs
        limit = json?["limit"]?.numberValue.flatMap { $0.isFinite ? Int(min(max($0, 1), Double(Self.maxLimit))) : nil } ?? 1000
        ascending = json?["order"]?.stringValue != "desc"
    }
}
