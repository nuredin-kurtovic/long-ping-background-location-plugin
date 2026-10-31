import Foundation

/// Moving/parked from the fixes themselves (DESIGN.md, "Stop detection"). Identical rules on both platforms.
struct StopDetector: Equatable {
    struct Settings: Equatable {
        var stopRadiusM: Double
        var stopTimeoutSec: Double
        var movingSpeedMps: Double
        var minAccuracyM: Double
        var disabled: Bool

        init(stopRadiusM: Double, stopTimeoutSec: Double, movingSpeedMps: Double, minAccuracyM: Double, disabled: Bool) {
            self.stopRadiusM = stopRadiusM
            self.stopTimeoutSec = stopTimeoutSec
            self.movingSpeedMps = movingSpeedMps
            self.minAccuracyM = minAccuracyM
            self.disabled = disabled
        }

        init(_ config: LongPingConfig) {
            self.init(stopRadiusM: config.stopRadiusM, stopTimeoutSec: config.stopTimeoutSec,
                      movingSpeedMps: config.movingSpeedMps, minAccuracyM: config.minAccuracyM,
                      disabled: config.disableStopDetection)
        }

        /// Fixes less accurate than this are ignored by the detector.
        var evaluationAccuracy: Double {
            minAccuracyM == 0 ? stopRadiusM : max(minAccuracyM, stopRadiusM)
        }
    }

    enum Transition: Equatable {
        case none
        case parked(at: Fix)
        case moved(Fix)
    }

    /// Accuracy a fix needs for a speed-based move out of parked.
    static let speedMoveAccuracyM = 50.0

    private(set) var isMoving: Bool
    private(set) var anchor: Fix?
    private(set) var parkedAt: Fix?

    init(isMoving: Bool = true, anchor: Fix? = nil, parkedAt: Fix? = nil) {
        self.isMoving = isMoving
        self.anchor = anchor
        self.parkedAt = parkedAt
    }

    mutating func process(_ fix: Fix, settings: Settings) -> Transition {
        guard fix.accuracy <= settings.evaluationAccuracy else { return .none }
        if isMoving {
            return processMoving(fix, settings)
        }
        return processParked(fix, settings)
    }

    private mutating func processMoving(_ fix: Fix, _ s: Settings) -> Transition {
        guard let anchor, !s.disabled else {
            anchor = fix
            return .none
        }
        if fix.distance(to: anchor) > s.stopRadiusM || fix.speed >= s.movingSpeedMps {
            self.anchor = fix
            return .none
        }
        if fix.time - anchor.time >= EpochMs(seconds: s.stopTimeoutSec) {
            isMoving = false
            parkedAt = fix
            return .parked(at: fix)
        }
        return .none
    }

    private mutating func processParked(_ fix: Fix, _ s: Settings) -> Transition {
        if s.disabled { return move(fix) }
        guard let parkedAt else {
            // Parked without a position (changePace(false) before any fix): the first usable fix is the spot.
            self.parkedAt = fix
            return .none
        }
        if fix.speed >= s.movingSpeedMps, fix.accuracy <= Self.speedMoveAccuracyM {
            return move(fix)
        }
        if fix.distance(to: parkedAt) > s.stopRadiusM, fix.accuracy <= s.stopRadiusM {
            return move(fix)
        }
        return .none
    }

    private mutating func move(_ fix: Fix) -> Transition {
        isMoving = true
        anchor = fix
        parkedAt = nil
        return .moved(fix)
    }

    /// `changePace(true)` and region exit: moving now, anchored at `fix` (or the next fix).
    mutating func forceMoving(at fix: Fix?) {
        isMoving = true
        anchor = fix
        parkedAt = nil
    }

    /// `changePace(false)`: parked at the last fix (or the next usable one).
    mutating func forceParked(at fix: Fix?) {
        isMoving = false
        parkedAt = fix
        anchor = nil
    }

    /// `changePace()`. The last fix becomes the anchor / parked spot only if it is fresh and accurate, and is then
    /// returned to be recorded as the motionchange at once. Otherwise the state is forced with no point and nil is
    /// returned: the next fix becomes the point and is recorded as the motionchange. A point that is not recorded
    /// right away would judge the next fix and could undo the forced state before its motionchange exists.
    mutating func changePace(_ isMoving: Bool, lastFix: Fix?, now: EpochMs, minAccuracyM: Double) -> Fix? {
        let here = PendingMotionChange.immediateFix(lastFix: lastFix, now: now, minAccuracyM: minAccuracyM)
        if isMoving {
            forceMoving(at: here)
        } else {
            forceParked(at: here)
        }
        return here
    }
}
