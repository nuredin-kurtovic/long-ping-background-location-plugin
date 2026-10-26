package com.longping.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntervalsTest {
    private val config = LongPingConfig(movingIntervalSec = 10.0, parkedIntervalSec = 120.0, lowBattery = LowBattery(20.0, 300.0))

    @Test fun movingAndParkedBase() {
        val full = BatteryState(0.9, false)
        assertEquals(10.0, Intervals.effectiveIntervalSec(config, true, full), 0.0)
        assertEquals(120.0, Intervals.effectiveIntervalSec(config, false, full), 0.0)
        assertEquals(LocationRequestSpec(Accuracy.HIGH, 10_000), Intervals.requestSpec(config, true, full))
    }

    @Test fun lowBatteryRaisesTheIntervalOnlyWhenDischargingAndBelowThreshold() {
        assertEquals(300.0, Intervals.effectiveIntervalSec(config, true, BatteryState(0.19, false)), 0.0)
        assertEquals(300.0, Intervals.effectiveIntervalSec(config, false, BatteryState(0.05, false)), 0.0)
        assertEquals(10.0, Intervals.effectiveIntervalSec(config, true, BatteryState(0.19, true)), 0.0)
        assertEquals(10.0, Intervals.effectiveIntervalSec(config, true, BatteryState(0.20, false)), 0.0)
        assertEquals(10.0, Intervals.effectiveIntervalSec(config, true, BatteryState.UNKNOWN), 0.0)
        // max(base, low.intervalSec): a parked interval already above it stays
        val longParked = config.copy(parkedIntervalSec = 900.0)
        assertEquals(900.0, Intervals.effectiveIntervalSec(longParked, false, BatteryState(0.1, false)), 0.0)
        assertEquals(10.0, Intervals.effectiveIntervalSec(config.copy(lowBattery = null), true, BatteryState(0.01, false)), 0.0)
    }

    @Test fun batteryFromRaw() {
        assertEquals(BatteryState(0.5, true), BatteryState.fromRaw(50, 100, true))
        assertEquals(-1.0, BatteryState.fromRaw(-1, 100, false).level, 0.0)
        assertEquals(-1.0, BatteryState.fromRaw(50, 0, false).level, 0.0)
    }

    @Test fun msUntilDueIsWhenTheRecordingRuleAcceptsTheNextFix() {
        // Last record at 100_000, 60 s interval, 0.5 s tolerance -> due at 159_500.
        assertEquals(2_500L, Intervals.msUntilDue(100_000, 60_000, 157_000))
        assertEquals(0L, Intervals.msUntilDue(100_000, 60_000, 170_000))
        assertNull(Intervals.msUntilDue(null, 60_000, 157_000))
    }

    @Test fun toleranceIsMinOfHalfASecondAndTenPercent() {
        assertEquals(500, Intervals.toleranceMs(30_000))
        assertEquals(500, Intervals.toleranceMs(5_000))
        assertEquals(100, Intervals.toleranceMs(1_000))
    }

    @Test fun watchdogStaleness() {
        // short interval: interval + 60 s dominates
        assertFalse(Intervals.isLocationStale(nowMs = 70_000, lastFixMs = 0, intervalMs = 10_000))
        assertTrue(Intervals.isLocationStale(nowMs = 70_001, lastFixMs = 0, intervalMs = 10_000))
        // long interval: 2 x interval dominates
        assertFalse(Intervals.isLocationStale(nowMs = 360_000, lastFixMs = 0, intervalMs = 180_000))
        assertTrue(Intervals.isLocationStale(nowMs = 360_001, lastFixMs = 0, intervalMs = 180_000))
    }
}

class GeoTest {
    @Test fun oneDegreeOfLatitude() {
        val expected = Geo.EARTH_RADIUS_M * Math.PI / 180
        assertEquals(expected, Geo.distanceM(0.0, 0.0, 1.0, 0.0), 1e-6)
        assertEquals(expected, Geo.distanceM(0.0, 0.0, 0.0, 1.0), 1e-6)
        assertEquals(111_195.08, expected, 0.01)
    }

    @Test fun knownCityPairAndSymmetry() {
        val paris = doubleArrayOf(48.8566, 2.3522)
        val london = doubleArrayOf(51.5074, -0.1278)
        val d = Geo.distanceM(paris[0], paris[1], london[0], london[1])
        assertEquals(343_560.0, d, 500.0)
        assertEquals(d, Geo.distanceM(london[0], london[1], paris[0], paris[1]), 1e-6)
        assertEquals(0.0, Geo.distanceM(43.85, 18.41, 43.85, 18.41), 0.0)
        assertEquals(Math.PI * Geo.EARTH_RADIUS_M, Geo.distanceM(0.0, 0.0, 0.0, 180.0), 1e-3)
    }
}
