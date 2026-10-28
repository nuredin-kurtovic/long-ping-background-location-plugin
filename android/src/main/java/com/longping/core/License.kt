package com.longping.core

import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

enum class LicenseStatus(val wire: String) {
    VALID("valid"),
    DEBUG("debug"),
    INVALID("invalid"),
    MISSING("missing"),
}

/** Outcome of checking a key string. [status] is VALID, INVALID or MISSING; [reason] is for the log. */
data class LicenseCheck(val status: LicenseStatus, val reason: String, val subject: String? = null)

/**
 * DESIGN.md, "License": `LP1.<payload>.<signature>`, ECDSA P-256 / SHA-256 (DER) over the ASCII
 * bytes of `LP1.<payload>`. A key never expires at runtime; `upd` only bounds which plugin
 * releases it covers.
 */
class LicenseVerifier(
    publicKeySpkiBase64: String = PUBLIC_KEY_SPKI_BASE64,
    private val releaseDate: String = PLUGIN_RELEASE_DATE,
) {
    private val publicKey: PublicKey =
        KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(Base64Url.decode(publicKeySpkiBase64)))

    fun verify(key: String?, appId: String): LicenseCheck {
        val trimmed = key?.trim()
        if (trimmed.isNullOrEmpty()) return LicenseCheck(LicenseStatus.MISSING, "no licenseKey configured")
        val parts = trimmed.split('.')
        if (parts.size != 3 || parts[0] != "LP1") return invalid("not an LP1 key")

        val signature = try {
            Base64Url.decode(parts[2])
        } catch (e: IllegalArgumentException) {
            return invalid("signature is not base64url")
        }
        val signedOk = try {
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(publicKey)
                update("${parts[0]}.${parts[1]}".toByteArray(Charsets.US_ASCII))
                verify(signature)
            }
        } catch (e: Exception) {
            false // malformed DER throws SignatureException: same verdict as a wrong signature
        }
        if (!signedOk) return invalid("bad signature")

        val payload = try {
            JSONObject(String(Base64Url.decode(parts[1]), Charsets.UTF_8))
        } catch (e: Exception) {
            return invalid("payload is not JSON")
        }
        val subject = Json.value(payload, "sub") as? String
        if ((Json.value(payload, "v") as? Number)?.toDouble() != 1.0) return invalid("unsupported version", subject)

        val apps = (Json.value(payload, "apps") as? JSONArray)?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.opt(it) as? String }
        } ?: return invalid("no apps", subject)
        if (!appMatches(apps, appId)) return invalid("app $appId is not covered (apps: ${apps.joinToString()})", subject)

        when (val upd = Json.value(payload, "upd")) {
            null -> Unit
            is String -> {
                if (!DATE.matches(upd)) return invalid("upd is not YYYY-MM-DD", subject)
                if (releaseDate > upd) {
                    return invalid("covers releases up to $upd; this release is $releaseDate", subject)
                }
            }
            else -> return invalid("upd is not a string", subject)
        }
        return LicenseCheck(LicenseStatus.VALID, "valid", subject)
    }

    private fun invalid(reason: String, subject: String? = null) = LicenseCheck(LicenseStatus.INVALID, reason, subject)

    companion object {
        const val PLUGIN_RELEASE_DATE = "2026-10-28"
        const val PUBLIC_KEY_SPKI_BASE64 =
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfz4a/OgAm9wr//FwRGIEJr+t4l2Mbj7E7b0jaVLwb0x+f+YUg6XZCBmzW6x2zF9sy4yVqBKSj8v0dt9lC9xLhQ=="

        private val DATE = Regex("""^\d{4}-\d{2}-\d{2}$""")

        /** Exact id, or a `prefix.*` pattern matching ids that start with `prefix.`. */
        fun appMatches(patterns: List<String>, appId: String): Boolean = patterns.any { p ->
            if (p.endsWith(".*")) appId.startsWith(p.substring(0, p.length - 1)) else p == appId
        }

        /** A valid key reports 'valid' even in debug builds; otherwise debug builds and emulators run as 'debug'. */
        fun effectiveStatus(check: LicenseCheck, debugBuildOrEmulator: Boolean): LicenseStatus = when {
            check.status == LicenseStatus.VALID -> LicenseStatus.VALID
            debugBuildOrEmulator -> LicenseStatus.DEBUG
            else -> check.status
        }

        fun allowsTracking(status: LicenseStatus) = status == LicenseStatus.VALID || status == LicenseStatus.DEBUG
    }
}

/** Base64 decoder accepting both alphabets, with or without padding (java.util.Base64 needs API 26). */
object Base64Url {
    private val TABLE = IntArray(128) { -1 }.also { t ->
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".forEachIndexed { i, c -> t[c.code] = i }
        t['+'.code] = 62
        t['-'.code] = 62
        t['/'.code] = 63
        t['_'.code] = 63
    }

    fun decode(input: String): ByteArray {
        val s = input.trimEnd('=')
        if (s.length % 4 == 1) throw IllegalArgumentException("bad base64 length")
        val out = java.io.ByteArrayOutputStream(s.length * 3 / 4)
        var buffer = 0
        var bits = 0
        for (c in s) {
            val v = if (c.code < 128) TABLE[c.code] else -1
            if (v < 0) throw IllegalArgumentException("bad base64 character '$c'")
            buffer = (buffer shl 6) or v
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.write((buffer shr bits) and 0xFF)
            }
        }
        return out.toByteArray()
    }
}
