package com.longping.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigResolverTest {
    private fun resolve(text: String) = ConfigResolver.resolve(json(text)).config

    @Test fun defaultsMatchTheContract() {
        val c = resolve("{}")
        assertNull(c.licenseKey)
        assertEquals(30.0, c.movingIntervalSec, 0.0)
        assertEquals(180.0, c.parkedIntervalSec, 0.0)
        assertEquals(Accuracy.HIGH, c.accuracy)
        assertEquals(100.0, c.minAccuracyM, 0.0)
        assertEquals(300.0, c.stopTimeoutSec, 0.0)
        assertEquals(75.0, c.stopRadiusM, 0.0)
        assertEquals(3.0, c.movingSpeedMps, 0.0)
        assertFalse(c.disableStopDetection)
        assertNull(c.lowBattery)
        assertNull(c.http.url)
        assertFalse(c.http.uploadsEnabled)
        assertEquals(HttpMethod.POST, c.http.method)
        assertTrue(c.http.headers.isEmpty())
        assertTrue(c.http.batch)
        assertEquals(100, c.http.maxBatchSize)
        assertEquals(0.0, c.http.uploadIntervalSec, 0.0)
        assertNull(c.http.rootProperty)
        assertNull(c.http.locationTemplate)
        assertEquals(0, c.http.params().length())
        assertEquals(0, c.http.extras().length())
        assertEquals(30.0, c.http.timeoutSec, 0.0)
        assertEquals(10_000, c.persistence.maxRecords)
        assertEquals(7, c.persistence.maxDays)
        assertTrue(c.startOnBoot)
        assertFalse(c.stopOnTerminate)
        assertTrue(c.remoteConfig)
        assertEquals("Location tracking", c.notification.title)
        assertEquals("Sharing your location", c.notification.text)
        assertEquals("Location tracking", c.notification.channelName)
        assertNull(c.notification.smallIcon)
        assertEquals(NotificationPriority.LOW, c.notification.priority)
        assertFalse(c.ios.showsBackgroundLocationIndicator)
        assertEquals(IosActivityType.AUTOMOTIVE, c.ios.activityType)
        assertEquals(LogLevel.INFO, c.logLevel)
        assertEquals(3, c.logMaxDays)
        assertFalse(c.debug)
        assertEquals(ConfigResolver.defaults(), c)
    }

    @Test fun toJsonHasEveryKeyAndRoundTrips() {
        val c = resolve(
            """{"licenseKey":"LP1.a.b","movingIntervalSec":5,"lowBattery":{"belowPct":20,"intervalSec":600},
               "http":{"url":"https://x.test/l","headers":{"X-A":"1"},"params":{"p":[1,2]},"extras":{"e":true},
               "locationTemplate":"{\"lat\":{{latitude}}}"},"notification":{"smallIcon":"ic_stat"},"debug":true}""",
        )
        val j = c.toJson()
        listOf(
            "licenseKey", "movingIntervalSec", "parkedIntervalSec", "accuracy", "minAccuracyM", "stopTimeoutSec",
            "stopRadiusM", "movingSpeedMps", "disableStopDetection", "lowBattery", "http", "persistence", "startOnBoot",
            "stopOnTerminate", "remoteConfig", "notification", "ios", "logLevel", "logMaxDays", "debug",
        ).forEach { assertTrue(it, j.has(it)) }
        assertEquals(11, j.getJSONObject("http").length())
        assertEquals(c, ConfigResolver.resolve(j).config)
        assertEquals(c, ConfigResolver.restore(j.toString()))
        assertTrue(ConfigResolver.resolve(j).unknownKeys.isEmpty())
    }

    @Test fun clampsEveryRange() {
        val low = resolve(
            """{"movingIntervalSec":0,"parkedIntervalSec":-5,"stopTimeoutSec":1,"stopRadiusM":1,"movingSpeedMps":0,
               "http":{"maxBatchSize":0,"timeoutSec":1,"uploadIntervalSec":-1},"persistence":{"maxRecords":0,"maxDays":0},
               "logMaxDays":0,"lowBattery":{"belowPct":-10,"intervalSec":0}}""",
        )
        assertEquals(1.0, low.movingIntervalSec, 0.0)
        assertEquals(1.0, low.parkedIntervalSec, 0.0)
        assertEquals(30.0, low.stopTimeoutSec, 0.0)
        assertEquals(10.0, low.stopRadiusM, 0.0)
        assertEquals(0.5, low.movingSpeedMps, 0.0)
        assertEquals(1, low.http.maxBatchSize)
        assertEquals(5.0, low.http.timeoutSec, 0.0)
        assertEquals(0.0, low.http.uploadIntervalSec, 0.0)
        assertEquals(1, low.persistence.maxRecords)
        assertEquals(1, low.persistence.maxDays)
        assertEquals(1, low.logMaxDays)
        assertEquals(LowBattery(0.0, 1.0), low.lowBattery)

        val high = resolve(
            """{"movingIntervalSec":1e9,"parkedIntervalSec":90000,"stopTimeoutSec":1e9,"stopRadiusM":1e9,"movingSpeedMps":1e9,
               "http":{"maxBatchSize":5000,"timeoutSec":500},"persistence":{"maxRecords":5e7,"maxDays":1000},"logMaxDays":99,
               "lowBattery":{"belowPct":250,"intervalSec":1e9}}""",
        )
        assertEquals(86_400.0, high.movingIntervalSec, 0.0)
        assertEquals(86_400.0, high.parkedIntervalSec, 0.0)
        assertEquals(86_400.0, high.stopTimeoutSec, 0.0)
        assertEquals(10_000.0, high.stopRadiusM, 0.0)
        assertEquals(100.0, high.movingSpeedMps, 0.0)
        assertEquals(1000, high.http.maxBatchSize)
        assertEquals(120.0, high.http.timeoutSec, 0.0)
        assertEquals(1_000_000, high.persistence.maxRecords)
        assertEquals(365, high.persistence.maxDays)
        assertEquals(30, high.logMaxDays)
        assertEquals(LowBattery(100.0, 86_400.0), high.lowBattery)
    }

    @Test fun fractionalIntervalsAreKeptAndCountsRounded() {
        val c = resolve("""{"movingIntervalSec":1.5,"http":{"maxBatchSize":10.6}}""")
        assertEquals(1.5, c.movingIntervalSec, 0.0)
        assertEquals(11, c.http.maxBatchSize)
    }

    @Test fun wrongTypesRejectNamingTheKey() {
        assertThrowsConfig("movingIntervalSec") { resolve("""{"movingIntervalSec":"30"}""") }
        assertThrowsConfig("disableStopDetection") { resolve("""{"disableStopDetection":"yes"}""") }
        assertThrowsConfig("accuracy") { resolve("""{"accuracy":"ultra"}""") }
        assertThrowsConfig("accuracy") { resolve("""{"accuracy":1}""") }
        assertThrowsConfig("licenseKey") { resolve("""{"licenseKey":42}""") }
        assertThrowsConfig("http") { resolve("""{"http":"https://x"}""") }
        assertThrowsConfig("http.maxBatchSize") { resolve("""{"http":{"maxBatchSize":"many"}}""") }
        assertThrowsConfig("http.batch") { resolve("""{"http":{"batch":1}}""") }
        assertThrowsConfig("http.method") { resolve("""{"http":{"method":"GET"}}""") }
        assertThrowsConfig("http.params") { resolve("""{"http":{"params":[1]}}""") }
        assertThrowsConfig("http.extras") { resolve("""{"http":{"extras":"x"}}""") }
        assertThrowsConfig("http.headers.X-Count") { resolve("""{"http":{"headers":{"X-Count":5}}}""") }
        assertThrowsConfig("http.headers.Bad Name") { resolve("""{"http":{"headers":{"Bad Name":"v"}}}""") }
        assertThrowsConfig("http.headers.X-A") { resolve("""{"http":{"headers":{"X-A":"a\r\nInjected: 1"}}}""") }
        assertThrowsConfig("persistence.maxDays") { resolve("""{"persistence":{"maxDays":true}}""") }
        assertThrowsConfig("notification.priority") { resolve("""{"notification":{"priority":"max"}}""") }
        assertThrowsConfig("notification.title") { resolve("""{"notification":{"title":5}}""") }
        assertThrowsConfig("ios.activityType") { resolve("""{"ios":{"activityType":"walking"}}""") }
        assertThrowsConfig("logLevel") { resolve("""{"logLevel":"verbose"}""") }
        assertThrowsConfig("lowBattery") { resolve("""{"lowBattery":20}""") }
        assertThrowsConfig("lowBattery.intervalSec") { resolve("""{"lowBattery":{"belowPct":20}}""") }
        assertThrowsConfig("minAccuracyM") { resolve("""{"minAccuracyM":-1}""") }
    }

    @Test fun urlValidationAndEmptyStringMeansRecordOnly() {
        assertNull(resolve("""{"http":{"url":""}}""").http.url)
        assertNull(resolve("""{"http":{"url":null}}""").http.url)
        assertEquals("https://api.test/v1/loc", resolve("""{"http":{"url":"https://api.test/v1/loc"}}""").http.url)
        assertTrue(resolve("""{"http":{"url":"http://10.0.2.2:8000/x"}}""").http.uploadsEnabled)
        assertThrowsConfig("http.url") { resolve("""{"http":{"url":"ftp://x.test"}}""") }
        assertThrowsConfig("http.url") { resolve("""{"http":{"url":"not a url"}}""") }
        assertThrowsConfig("http.url") { resolve("""{"http":{"url":"https://"}}""") }
    }

    @Test fun nullOnANonNullableKeyMeansDefault() {
        val c = resolve("""{"movingIntervalSec":null,"http":{"batch":null,"headers":null},"notification":null}""")
        assertEquals(30.0, c.movingIntervalSec, 0.0)
        assertTrue(c.http.batch)
        assertEquals(NotificationConfig(), c.notification)
    }

    @Test fun methodIsCaseInsensitive() {
        assertEquals(HttpMethod.PUT, resolve("""{"http":{"method":"put"}}""").http.method)
    }

    @Test fun rootPropertyDotIsAcceptedInBothModes() {
        assertEquals(".", resolve("""{"http":{"batch":false,"rootProperty":"."}}""").http.rootProperty)
        // With batch on it is kept and the body falls back to 'locations' (see UploadBody.batch).
        assertEquals(".", resolve("""{"http":{"rootProperty":"."}}""").http.rootProperty)
        assertNull(resolve("""{"http":{"rootProperty":""}}""").http.rootProperty)
    }

    @Test fun templateIsValidatedAtConfigure() {
        val ok = """{"lat":{{latitude}},"lng":{{longitude}},"at":"{{timestamp}}","x":{{extras}}}"""
        assertEquals(ok, resolve(JSONObject().put("http", JSONObject().put("locationTemplate", ok)).toString()).http.locationTemplate)

        val unknownToken = JSONObject().put("http", JSONObject().put("locationTemplate", """{"a":{{lattitude}}}"""))
        val e1 = assertThrowsConfig("http.locationTemplate") { ConfigResolver.resolve(unknownToken) }
        assertTrue(e1.message!!.contains("{{lattitude}}"))

        val unquoted = JSONObject().put("http", JSONObject().put("locationTemplate", """{"at":{{timestamp}}}"""))
        assertThrowsConfig("http.locationTemplate") { ConfigResolver.resolve(unquoted) }

        val array = JSONObject().put("http", JSONObject().put("batch", false).put("rootProperty", ".").put("locationTemplate", "[{{latitude}}]"))
        assertThrowsConfig("http.locationTemplate") { ConfigResolver.resolve(array) }
    }

    @Test fun unknownKeysAreReportedAndDropped() {
        val r = ConfigResolver.resolve(json("""{"foo":1,"http":{"bar":2,"url":null},"persistence":{"baz":3},"lowBattery":{"belowPct":5,"intervalSec":60,"q":1}}"""))
        assertEquals(setOf("foo", "http.bar", "persistence.baz", "lowBattery.q"), r.unknownKeys.toSet())
        assertFalse(r.config.toJson().has("foo"))
    }

    @Test fun mergeIsDeepForObjectsAndReplacesScalarsAndArrays() {
        val base = resolve(
            """{"movingIntervalSec":10,"http":{"url":"https://a.test","headers":{"A":"1"},"params":{"p":{"x":1},"list":[1,2]}},
               "lowBattery":{"belowPct":20,"intervalSec":300}}""",
        )
        val merged = ConfigResolver.merge(
            base,
            json("""{"parkedIntervalSec":60,"http":{"headers":{"B":"2"},"params":{"p":{"y":2},"list":[3]}},"lowBattery":{"belowPct":15}}"""),
        ).config
        assertEquals(10.0, merged.movingIntervalSec, 0.0)
        assertEquals(60.0, merged.parkedIntervalSec, 0.0)
        assertEquals("https://a.test", merged.http.url)
        assertEquals(mapOf("A" to "1", "B" to "2"), merged.http.headers)
        val params = merged.http.params()
        assertEquals(1, params.getJSONObject("p").getInt("x"))
        assertEquals(2, params.getJSONObject("p").getInt("y"))
        assertEquals(1, params.getJSONArray("list").length())
        assertEquals(LowBattery(15.0, 300.0), merged.lowBattery)

        val cleared = ConfigResolver.merge(merged, json("""{"lowBattery":null,"http":{"url":""}}""")).config
        assertNull(cleared.lowBattery)
        assertNull(cleared.http.url)
    }

    @Test fun configureReplacesTheWholeConfig() {
        resolve("""{"movingIntervalSec":10,"debug":true}""")
        val again = resolve("""{"parkedIntervalSec":60}""")
        assertEquals(30.0, again.movingIntervalSec, 0.0)
        assertFalse(again.debug)
    }

    @Test fun mergeStillValidates() {
        val base = resolve("""{"http":{"batch":false}}""")
        assertThrowsConfig("http.maxBatchSize") { ConfigResolver.merge(base, json("""{"http":{"maxBatchSize":"ten"}}""")) }
    }

    @Test fun flippingBatchOnKeepsADotRootProperty() {
        val base = resolve("""{"http":{"batch":false,"rootProperty":"."}}""")
        val merged = ConfigResolver.merge(base, json("""{"http":{"batch":true}}""")).config
        assertTrue(merged.http.batch)
        assertEquals(".", merged.http.rootProperty)
    }

    @Test fun restoreFallsBackToDefaultsOnGarbage() {
        assertEquals(ConfigResolver.defaults(), ConfigResolver.restore(null))
        assertEquals(ConfigResolver.defaults(), ConfigResolver.restore("not json"))
        assertEquals(ConfigResolver.defaults(), ConfigResolver.restore("""{"movingIntervalSec":"x"}"""))
    }

    @Test fun licenseKeyBlankIsNull() {
        assertNull(resolve("""{"licenseKey":"   "}""").licenseKey)
        assertEquals("LP1.x.y", resolve("""{"licenseKey":" LP1.x.y "}""").licenseKey)
    }
}
