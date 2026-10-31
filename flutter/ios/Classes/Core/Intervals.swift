import Foundation

/// Battery as the engine sees it. `level` is 0...1, or -1 when unknown.
struct BatterySnapshot: Equatable {
    var level: Double
    var isCharging: Bool

    static let unknown = BatterySnapshot(level: -1, isCharging: false)
}

enum IntervalPolicy {
    /// DESIGN.md, "Effective interval".
    static func effectiveInterval(isMoving: Bool, config: LongPingConfig, battery: BatterySnapshot) -> Double {
        var base = isMoving ? config.movingIntervalSec : config.parkedIntervalSec
        if let low = config.lowBattery, !battery.isCharging, battery.level >= 0, battery.level * 100 < low.belowPct {
            base = max(base, low.intervalSec)
        }
        return base
    }

    /// `min(0.5 s, 10% of interval)`, in ms. Half a second, not more: iOS delivers a fix every second, and a
    /// full second of slack recorded one fix early every time (10 s became 9 s).
    static func toleranceMs(intervalSec: Double) -> EpochMs {
        EpochMs(seconds: min(0.5, intervalSec * 0.1))
    }
}

/// Recording rule + overdue rule (DESIGN.md, "Recording rule").
struct RecordingGate: Equatable {
    enum Decision: Equatable {
        /// Record this fix. `accuracyWaived` = overdue rule fired.
        case record(Fix, accuracyWaived: Bool)
        /// Due, but less accurate than `minAccuracyM`; kept as an overdue candidate.
        case inaccurate
        /// Arrived before the interval elapsed.
        case tooSoon
        /// Older than the last recorded fix (late cached delivery).
        case stale
    }

    /// Grace after the interval before the accuracy filter is waived.
    static let overdueGraceMs: EpochMs = 30_000

    private(set) var lastRecordedTime: EpochMs?
    /// When the gate started waiting without any record (tracking start); the overdue reference then.
    private(set) var armedAt: EpochMs
    /// Most accurate fix that failed the accuracy filter since the last record.
    private(set) var bestInaccurate: Fix?

    init(lastRecordedTime: EpochMs?, armedAt: EpochMs) {
        self.lastRecordedTime = lastRecordedTime
        self.armedAt = armedAt
    }

    static func isAccurate(_ fix: Fix, minAccuracyM: Double) -> Bool {
        minAccuracyM == 0 || fix.accuracy <= minAccuracyM
    }

    /// The interval clock when the engine starts. `lastRecordedTime` is persisted at most every 15 s, so after a
    /// kill the newest queued record or the last location can be later; without them the first fix after a
    /// relaunch could be recorded too early. Capped at `now`: a clock set back must not hold every new fix as stale.
    static func resumeTime(persisted: EpochMs?, newestQueued: EpochMs?, lastLocationAt: EpochMs?, now: EpochMs) -> EpochMs? {
        guard let newest = [persisted, newestQueued, lastLocationAt].compactMap({ $0 }).max() else { return nil }
        return min(newest, now)
    }

    mutating func evaluate(_ fix: Fix, now: EpochMs, intervalSec: Double, minAccuracyM: Double) -> Decision {
        if let last = lastRecordedTime {
            if fix.time < last { return .stale }
            let intervalMs = EpochMs(seconds: intervalSec)
            let due = fix.time - last >= intervalMs - IntervalPolicy.toleranceMs(intervalSec: intervalSec)
            guard due else { return .tooSoon }
        }
        if Self.isAccurate(fix, minAccuracyM: minAccuracyM) {
            markRecorded(fix.time)
            return .record(fix, accuracyWaived: false)
        }
        if fix.accuracy < (bestInaccurate?.accuracy ?? .infinity) {
            bestInaccurate = fix
        }
        if let overdue = takeOverdue(now: now, intervalSec: intervalSec) {
            return .record(overdue, accuracyWaived: true)
        }
        return .inaccurate
    }

    /// Overdue rule, also run from the watchdog: if nothing was recorded for interval + 30 s and only
    /// inaccurate fixes arrived, hand back the most accurate of them.
    mutating func takeOverdue(now: EpochMs, intervalSec: Double) -> Fix? {
        guard let best = bestInaccurate else { return nil }
        let reference = lastRecordedTime ?? armedAt
        guard now - reference > EpochMs(seconds: intervalSec) + Self.overdueGraceMs else { return nil }
        markRecorded(best.time)
        return best
    }

    /// Any record (motion change included) restarts the interval clock.
    mutating func markRecorded(_ time: EpochMs) {
        lastRecordedTime = max(time, lastRecordedTime ?? time)
        bestInaccurate = nil
    }

    /// Fresh start: no previous record counts.
    mutating func rearm(now: EpochMs) {
        lastRecordedTime = nil
        bestInaccurate = nil
        armedAt = now
    }
}

/// A motion change waiting for a fix to record (start(), changePace() and region exit without a fresh fix).
struct PendingMotionChange: Equatable {
    /// A fix up to this much older than the request still counts (CoreLocation delivers a cached fix first).
    static let freshnessMs: EpochMs = 10_000
    /// Same grace as the overdue rule: after this, the most accurate fix seen is recorded anyway.
    static let waiverMs: EpochMs = 30_000

    let isMoving: Bool
    let requestedAt: EpochMs
    private(set) var best: Fix?

    init(isMoving: Bool, requestedAt: EpochMs) {
        self.isMoving = isMoving
        self.requestedAt = requestedAt
    }

    /// A known recent fix that can be recorded right away, if any.
    static func immediateFix(lastFix: Fix?, now: EpochMs, minAccuracyM: Double) -> Fix? {
        guard let fix = lastFix, now - fix.time <= freshnessMs,
              RecordingGate.isAccurate(fix, minAccuracyM: minAccuracyM) else { return nil }
        return fix
    }

    /// Returns the fix to record for this motion change, or nil to keep waiting.
    mutating func offer(_ fix: Fix, now: EpochMs, minAccuracyM: Double) -> Fix? {
        guard fix.time >= requestedAt - Self.freshnessMs else { return nil }
        if RecordingGate.isAccurate(fix, minAccuracyM: minAccuracyM) { return fix }
        if fix.accuracy < (best?.accuracy ?? .infinity) { best = fix }
        return takeExpired(now: now)
    }

    /// After the waiver window, the most accurate fix seen (if any).
    func takeExpired(now: EpochMs) -> Fix? {
        guard now - requestedAt >= Self.waiverMs else { return nil }
        return best
    }
}

/// iOS low-power-between-fixes scheme (DESIGN.md, "Lifecycle and recovery → iOS").
enum SamplingPlan {
    enum Mode: Equatable {
        /// Configured accuracy (high → Best, balanced → HundredMeters, low → Kilometer).
        case configured
        /// kCLLocationAccuracyThreeKilometers: keeps the app alive between fixes at minimal cost.
        case lowPower
    }

    static let lowPowerMinIntervalSec = 60.0
    static let boostLeadMs: EpochMs = 15_000

    /// The mode to run now and, for low power, when to switch back to the configured accuracy.
    static func plan(now: EpochMs, intervalSec: Double, lastRecordedTime: EpochMs?,
                     needsFixNow: Bool) -> (mode: Mode, boostAt: EpochMs?) {
        guard intervalSec >= lowPowerMinIntervalSec, !needsFixNow, let last = lastRecordedTime else {
            return (.configured, nil)
        }
        let boostAt = last + EpochMs(seconds: intervalSec) - boostLeadMs
        if now >= boostAt { return (.configured, nil) }
        return (.lowPower, boostAt)
    }
}

enum Watchdog {
    static let tickSec = 60.0

    /// `now - lastFixTime > max(2 × interval, interval + 60 s)`.
    static func isStalled(now: EpochMs, lastFixTime: EpochMs, intervalSec: Double) -> Bool {
        let limit = max(2 * intervalSec, intervalSec + 60)
        return now - lastFixTime > EpochMs(seconds: limit)
    }
}
