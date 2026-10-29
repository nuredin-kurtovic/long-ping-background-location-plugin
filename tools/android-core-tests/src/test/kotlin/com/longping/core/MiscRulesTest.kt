package com.longping.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class AuthorizationStatusTest {
    @Test fun androidMapping() {
        assertEquals(3, AuthorizationStatus.android(foreground = true, background = true, askedBefore = true, shouldShowRationale = false))
        assertEquals(4, AuthorizationStatus.android(foreground = true, background = false, askedBefore = true, shouldShowRationale = false))
        assertEquals(0, AuthorizationStatus.android(foreground = false, background = false, askedBefore = false, shouldShowRationale = false))
        // denied once: Android still lets us ask
        assertEquals(0, AuthorizationStatus.android(foreground = false, background = false, askedBefore = true, shouldShowRationale = true))
        // "don't ask again" (or denied twice on 11+)
        assertEquals(2, AuthorizationStatus.android(foreground = false, background = false, askedBefore = true, shouldShowRationale = false))
        assertEquals(listOf(0, 1, 2, 3, 4), listOf(
            AuthorizationStatus.NOT_DETERMINED, AuthorizationStatus.RESTRICTED, AuthorizationStatus.DENIED,
            AuthorizationStatus.ALWAYS, AuthorizationStatus.WHEN_IN_USE,
        ))
    }
}

class LogFormatTest {
    private val t = Instant.parse("2026-10-26T12:00:00.123Z").toEpochMilli()

    @Test fun lineFormatIsExact() {
        assertEquals("2026-10-26T12:00:00.123Z INFO  [tag] message", LogFormat.line(t, LogLevel.INFO, "tag", "message"))
        assertEquals("2026-10-26T12:00:00.123Z WARN  [http] x", LogFormat.line(t, LogLevel.WARN, "http", "x"))
        assertEquals("2026-10-26T12:00:00.123Z ERROR [a] x", LogFormat.line(t, LogLevel.ERROR, "a", "x"))
        assertEquals("2026-10-26T12:00:00.123Z DEBUG [a] x", LogFormat.line(t, LogLevel.DEBUG, "a", "x"))
        assertEquals("2026-10-26T12:00:00.123Z INFO  [a] one\\ntwo\\nthree", LogFormat.line(t, LogLevel.INFO, "a", "one\ntwo\r\nthree"))
    }

    @Test fun levelFiltering() {
        assertTrue(LogLevel.INFO.allows(LogLevel.ERROR))
        assertTrue(LogLevel.INFO.allows(LogLevel.INFO))
        assertFalse(LogLevel.INFO.allows(LogLevel.DEBUG))
        assertTrue(LogLevel.DEBUG.allows(LogLevel.DEBUG))
        assertFalse(LogLevel.OFF.allows(LogLevel.ERROR))
        assertFalse(LogLevel.ERROR.allows(LogLevel.WARN))
    }

    @Test fun queryDefaultsAndValidation() {
        val q = LogQuery.parse(JSONObject(), nowMs = 100_000_000)
        assertEquals(LogQuery(100_000_000 - 86_400_000, 1000, ascending = true), q)
        assertEquals(LogQuery(5, 10, ascending = false), LogQuery.parse(json("""{"sinceMs":5,"limit":10,"order":"desc"}"""), 0))
        assertEquals(1, LogQuery.parse(json("""{"limit":0}"""), 0).limit)
        assertThrowsConfig("order") { LogQuery.parse(json("""{"order":"newest"}"""), 0) }
        assertThrowsConfig("limit") { LogQuery.parse(json("""{"limit":"all"}"""), 0) }
        assertThrowsConfig("sinceMs") { LogQuery.parse(json("""{"sinceMs":"today"}"""), 0) }
    }
}

class NotificationTextTest {
    @Test fun debugText() {
        assertEquals("Sharing · no fix yet · 0 queued", NotificationText.debug("Sharing", 0, null, 0))
        assertEquals("Sharing · fix 12s ago · 3 queued", NotificationText.debug("Sharing", 12_500, 0, 3))
        assertEquals("5m", NotificationText.age(300_000))
        assertEquals("2h 5m", NotificationText.age(7_500_000))
        assertEquals("0s", NotificationText.age(-5_000))
    }
}

class PowerManagerTargetsTest {
    @Test fun coversEveryOemInTheContract() {
        assertEquals(
            setOf("samsung", "xiaomi", "huawei", "oppo", "vivo", "oneplus", "asus", "letv", "meizu"),
            PowerManagerTargets.ALL.map { it.oem }.toSet(),
        )
        assertEquals(PowerManagerTargets.ALL.size, PowerManagerTargets.ALL.toSet().size)
    }

    @Test fun manifestDeclaresEveryPackageForResolveChecks() {
        val manifest = java.io.File(androidDir(), "src/main/AndroidManifest.xml").readText()
        PowerManagerTargets.PACKAGES.forEach { pkg ->
            assertTrue("<queries> is missing $pkg", manifest.contains("<package android:name=\"$pkg\" />"))
        }
        assertFalse("library must not request REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", manifest.contains("uses-permission android:name=\"android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS\""))
    }
}

class CurrentPositionTest {
    @Test fun optionDefaultsAndValidation() {
        val d = CurrentPositionOptions.parse(JSONObject(), Accuracy.BALANCED)
        assertEquals(CurrentPositionOptions(30.0, 0.0, Accuracy.BALANCED, false, null), d)
        assertEquals(30_000L, d.timeoutMs)
        val o = CurrentPositionOptions.parse(json("""{"timeoutSec":5000,"maximumAgeSec":-3,"accuracy":"low","persist":true,"extras":{"a":1}}"""), Accuracy.HIGH)
        assertEquals(600.0, o.timeoutSec, 0.0)
        assertEquals(0.0, o.maximumAgeSec, 0.0)
        assertEquals(Accuracy.LOW, o.accuracy)
        assertTrue(o.persist)
        assertEquals(1, o.extras!!.getInt("a"))
        assertThrowsConfig("timeoutSec") { CurrentPositionOptions.parse(json("""{"timeoutSec":"soon"}"""), Accuracy.HIGH) }
        assertThrowsConfig("accuracy") { CurrentPositionOptions.parse(json("""{"accuracy":"best"}"""), Accuracy.HIGH) }
        assertThrowsConfig("persist") { CurrentPositionOptions.parse(json("""{"persist":1}"""), Accuracy.HIGH) }
        assertThrowsConfig("extras") { CurrentPositionOptions.parse(json("""{"extras":[]}"""), Accuracy.HIGH) }
    }

    @Test fun cachedOnlyWithinMaximumAge() {
        val f = fix(timeMs = 10_000)
        assertNull(CurrentPositionPolicy.cached(f, 10_000, 0))
        assertEquals(f, CurrentPositionPolicy.cached(f, 15_000, 5_000))
        assertNull(CurrentPositionPolicy.cached(f, 15_001, 5_000))
        assertNull(CurrentPositionPolicy.cached(null, 0, 5_000))
    }

    @Test fun timeoutPrefersBestSeenThenRecentLastKnown() {
        val best = fix(accuracy = 80.0, timeMs = 100)
        val last = fix(accuracy = 5.0, timeMs = 0)
        assertEquals(best, CurrentPositionPolicy.onTimeout(best, last, 1_000))
        assertEquals(last, CurrentPositionPolicy.onTimeout(null, last, 599_999))
        assertNull(CurrentPositionPolicy.onTimeout(null, last, 600_000))
        assertNull(CurrentPositionPolicy.onTimeout(null, null, 0))
    }

    @Test fun earlyAnswerAndBestSelection() {
        assertTrue(CurrentPositionPolicy.isGoodEnough(fix(accuracy = 10.0), 50.0))
        assertFalse(CurrentPositionPolicy.isGoodEnough(fix(accuracy = 60.0), 50.0))
        assertTrue(CurrentPositionPolicy.isGoodEnough(fix(accuracy = 600.0), 0.0))
        val a = fix(accuracy = 30.0)
        val b = fix(accuracy = 20.0)
        assertEquals(b, CurrentPositionPolicy.better(a, b))
        assertEquals(b, CurrentPositionPolicy.better(b, a))
        assertEquals(a, CurrentPositionPolicy.better(null, a))
        assertEquals(fix(timeMs = 5), CurrentPositionPolicy.newest(fix(timeMs = 1), fix(timeMs = 5)))
        assertEquals(fix(timeMs = 1), CurrentPositionPolicy.newest(fix(timeMs = 1), null))
    }
}

class EngineStateTest {
    @Test fun roundTripsAndRestoresGarbageAsStopped() {
        val s = EngineState(true, false, GeoPoint(1.0, 2.0, 3.0, 4), GeoPoint(5.0, 6.0, 7.0, 8), 9, 10)
        assertEquals(s, EngineState.fromJson(s.toJson().toString()))
        assertEquals(EngineState(), EngineState.fromJson("{nope"))
        assertEquals(EngineState(), EngineState.fromJson(""))
        val bare = EngineState(enabled = true)
        assertEquals(bare, EngineState.fromJson(bare.toJson().toString()))
        assertEquals(MotionState(false, GeoPoint(1.0, 2.0, 3.0, 4), null), EngineState().withMotion(MotionState(false, GeoPoint(1.0, 2.0, 3.0, 4), null)).motion)
    }
}
