package com.longping.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class LicenseTest {
    /** Signed with the real seller key: apps ["com.example.app"], plan "pro", sub "test". */
    private val vectors: Map<String, String> = mapOf(
        // upd 2030-01-01
        "VALID_2030" to "LP1.eyJ2IjoxLCJzdWIiOiJ0ZXN0IiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiXSwicGxhbiI6InBybyIsInVwZCI6IjIwMzAtMDEtMDEifQ" +
            ".MEQCIDdXjyLfR51DvTPYWtgse-poKG6BXrl7gX4HtXV2sWX2AiBKeff7IVf5wI_fTHFmrV0lCDlSz5J_YBZzTyUkJkO6Lg",
        // upd 2026-01-01: updates ended before this release
        "UPD_2026_01_01" to "LP1.eyJ2IjoxLCJzdWIiOiJ0ZXN0IiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiXSwicGxhbiI6InBybyIsInVwZCI6IjIwMjYtMDEtMDEifQ" +
            ".MEUCIDW2PMDsQuTIbW4E8ET1n2S7Mvh3Qeg_NqZsCazx9lwHAiEA9EBqEf5MR0HBZsYgWv1GNtGbdRW0LojrasnfPc2mSjI",
        // VALID_2030 with its last character changed to 'A'
        "TAMPERED" to "LP1.eyJ2IjoxLCJzdWIiOiJ0ZXN0IiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiXSwicGxhbiI6InBybyIsInVwZCI6IjIwMzAtMDEtMDEifQ" +
            ".MEQCIDdXjyLfR51DvTPYWtgse-poKG6BXrl7gX4HtXV2sWX2AiBKeff7IVf5wI_fTHFmrV0lCDlSz5J_YBZzTyUkJkO6LA",
    )
    private val verifier = LicenseVerifier()
    private val app = "com.example.app"

    /** As the website's checkout issues it (openssl, no update date): apps com.example.app + com.example.app.android. */
    private val shopKey = "LP1.eyJ2IjoxLCJzdWIiOiJwYXlwYWw6VEVTVE9SREVSMTIzIiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiLCJjb20uZXhhbXBsZS5hcHAuYW5kcm9pZCJdLCJwbGFuIjoiYXBwIn0" +
        ".MEQCIAFYT7ksvG3WhJWy45xMvln4Hdi_Gz1kTz7JG09Rua99AiBmlaVDaXRceLxvef9Vs9j0wRx3aZk8rPhOfTV--OSKBw"

    @Test fun keyIssuedByTheCheckoutCoversBothItsAppsAndNothingElse() {
        for (id in listOf("com.example.app", "com.example.app.android")) {
            val check = verifier.verify(shopKey, id)
            assertEquals(check.reason, LicenseStatus.VALID, check.status)
            assertEquals("paypal:TESTORDER123", check.subject)
        }
        assertEquals(LicenseStatus.INVALID, verifier.verify(shopKey, "com.example.app.ios").status)
        assertEquals(LicenseStatus.INVALID, verifier.verify(shopKey, "com.example").status)
    }

    @Test fun releaseConstantsMatchTheContract() {
        assertEquals("2026-10-28", LicenseVerifier.PLUGIN_RELEASE_DATE)
        assertEquals(
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfz4a/OgAm9wr//FwRGIEJr+t4l2Mbj7E7b0jaVLwb0x+f+YUg6XZCBmzW6x2zF9sy4yVqBKSj8v0dt9lC9xLhQ==",
            LicenseVerifier.PUBLIC_KEY_SPKI_BASE64,
        )
    }

    @Test fun validKeyIsValid() {
        val check = verifier.verify(vectors.getValue("VALID_2030"), app)
        assertEquals(check.reason, LicenseStatus.VALID, check.status)
        assertEquals("test", check.subject)
    }

    @Test fun keyWhoseUpdatesEndedBeforeThisReleaseIsInvalid() {
        val check = verifier.verify(vectors.getValue("UPD_2026_01_01"), app)
        assertEquals(LicenseStatus.INVALID, check.status)
        assertTrue(check.reason, check.reason.contains("2026-01-01"))
        // ...but it is valid for releases up to its upd date: it never expires at runtime
        assertEquals(LicenseStatus.VALID, LicenseVerifier(releaseDate = "2026-01-01").verify(vectors.getValue("UPD_2026_01_01"), app).status)
        assertEquals(LicenseStatus.VALID, LicenseVerifier(releaseDate = "2025-06-30").verify(vectors.getValue("UPD_2026_01_01"), app).status)
    }

    @Test fun tamperedSignatureIsInvalid() {
        val check = verifier.verify(vectors.getValue("TAMPERED"), app)
        assertEquals(LicenseStatus.INVALID, check.status)
        assertEquals("bad signature", check.reason)
    }

    @Test fun otherAppIdIsInvalid() {
        assertEquals(LicenseStatus.INVALID, verifier.verify(vectors.getValue("VALID_2030"), "com.example.app2").status)
        assertEquals(LicenseStatus.INVALID, verifier.verify(vectors.getValue("VALID_2030"), "com.example").status)
    }

    @Test fun payloadSwapBreaksTheSignature() {
        val valid = vectors.getValue("VALID_2030").split('.')
        val otherPayload = Base64.getUrlEncoder().withoutPadding()
            .encodeToString("""{"v":1,"sub":"test","apps":["com.evil.*"],"plan":"pro"}""".toByteArray())
        assertEquals(LicenseStatus.INVALID, verifier.verify("LP1.$otherPayload.${valid[2]}", "com.evil.app").status)
    }

    @Test fun missingAndMalformedKeys() {
        assertEquals(LicenseStatus.MISSING, verifier.verify(null, app).status)
        assertEquals(LicenseStatus.MISSING, verifier.verify("  ", app).status)
        listOf("garbage", "LP2.a.b", "LP1.a", "LP1.a.b.c", "LP1.@@@.###", "LP1.eyJ2IjoxfQ.MEQCIA").forEach {
            assertEquals(it, LicenseStatus.INVALID, verifier.verify(it, app).status)
        }
    }

    @Test fun appPatterns() {
        assertTrue(LicenseVerifier.appMatches(listOf("com.bhx"), "com.bhx"))
        assertFalse(LicenseVerifier.appMatches(listOf("com.bhx"), "com.bhx.driver"))
        assertTrue(LicenseVerifier.appMatches(listOf("com.bhx.*"), "com.bhx.driver"))
        assertTrue(LicenseVerifier.appMatches(listOf("com.bhx.*"), "com.bhx.driver.dev"))
        assertFalse(LicenseVerifier.appMatches(listOf("com.bhx.*"), "com.bhx"))
        assertFalse(LicenseVerifier.appMatches(listOf("com.bhx.*"), "com.bhxpress"))
        assertTrue(LicenseVerifier.appMatches(listOf("org.a", "com.bhx", "com.bhx.*"), "com.bhx"))
        assertFalse(LicenseVerifier.appMatches(emptyList(), "com.bhx"))
    }

    @Test fun effectiveStatusForDebugBuildsAndEmulators() {
        val valid = LicenseCheck(LicenseStatus.VALID, "valid")
        val invalid = LicenseCheck(LicenseStatus.INVALID, "bad signature")
        val missing = LicenseCheck(LicenseStatus.MISSING, "none")
        assertEquals(LicenseStatus.VALID, LicenseVerifier.effectiveStatus(valid, debugBuildOrEmulator = true))
        assertEquals(LicenseStatus.DEBUG, LicenseVerifier.effectiveStatus(invalid, debugBuildOrEmulator = true))
        assertEquals(LicenseStatus.DEBUG, LicenseVerifier.effectiveStatus(missing, debugBuildOrEmulator = true))
        assertEquals(LicenseStatus.INVALID, LicenseVerifier.effectiveStatus(invalid, debugBuildOrEmulator = false))
        assertEquals(LicenseStatus.MISSING, LicenseVerifier.effectiveStatus(missing, debugBuildOrEmulator = false))
        assertTrue(LicenseVerifier.allowsTracking(LicenseStatus.VALID))
        assertTrue(LicenseVerifier.allowsTracking(LicenseStatus.DEBUG))
        assertFalse(LicenseVerifier.allowsTracking(LicenseStatus.INVALID))
        assertFalse(LicenseVerifier.allowsTracking(LicenseStatus.MISSING))
        assertEquals(listOf("valid", "debug", "invalid", "missing"), LicenseStatus.entries.map { it.wire })
    }

    @Test fun base64DecoderMatchesTheJdkForBothAlphabets() {
        val rnd = java.util.Random(1)
        repeat(500) { n ->
            val bytes = ByteArray(n % 67).also { rnd.nextBytes(it) }
            assertArrayEquals(bytes, Base64Url.decode(Base64.getEncoder().encodeToString(bytes)))
            assertArrayEquals(bytes, Base64Url.decode(Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)))
        }
        try {
            Base64Url.decode("ab*d")
            throw AssertionError("expected failure")
        } catch (expected: IllegalArgumentException) {
        }
    }
}
