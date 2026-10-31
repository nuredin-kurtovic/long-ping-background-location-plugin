package com.longping.core

import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

/** DESIGN.md, "Upload" body rules. Record texts are inserted verbatim (no re-serialisation). */
object UploadBody {
    const val DEFAULT_BATCH_ROOT = "locations"
    const val DEFAULT_SINGLE_ROOT = "location"

    /** The JSON text sent for one stored record: the record itself or the rendered template. */
    fun recordText(storedJson: String, template: String?): String =
        if (template == null) storedJson else LocationTemplate.render(template, JSONObject(storedJson))

    /** `{ ...params, [rootProperty ?? 'locations']: [r1, r2, ...] }`; '.' (single-only) also means 'locations'. */
    fun batch(records: List<String>, params: JSONObject, rootProperty: String?): String =
        withRawMember(params, rootProperty?.takeIf { it != "." } ?: DEFAULT_BATCH_ROOT, records.joinToString(",", "[", "]"))

    /** `{ ...params, ...r }` for rootProperty '.', else `{ ...params, [rootProperty ?? 'location']: r }`. */
    fun single(record: String, params: JSONObject, rootProperty: String?): String {
        if (rootProperty != ".") return withRawMember(params, rootProperty ?: DEFAULT_SINGLE_ROOT, record)
        val out = Json.copy(params)
        val rec = JSONObject(record)
        for (key in Json.keys(rec)) out.put(key, rec.opt(key))
        return out.toString()
    }

    private fun withRawMember(params: JSONObject, key: String, rawValue: String): String {
        val rest = Json.copy(params)
        rest.remove(key)
        val member = JSONObject.quote(key) + ":" + rawValue
        if (rest.length() == 0) return "{$member}"
        val head = rest.toString()
        return head.substring(0, head.length - 1) + "," + member + "}"
    }
}

/** How one HTTP response (status 0 = network error / timeout) is handled. */
sealed class UploadVerdict {
    object Delivered : UploadVerdict()
    data class AuthFailed(val status: Int) : UploadVerdict()
    data class Shrink(val batchSize: Int) : UploadVerdict()
    data class RetryLater(val status: Int) : UploadVerdict()
    data class Rejected(val status: Int) : UploadVerdict()
}

object UploadPolicy {
    const val MAX_ATTEMPTS = 3
    const val MAX_BACKOFF_SEC = 900L
    const val BASE_BACKOFF_SEC = 10L
    const val MAX_RETRY_AFTER_SEC = 86_400L

    /**
     * - 2xx delivered; 401/403 auth; 413 halve (a single record that is still too large is
     *   handled like any other 4xx, otherwise it would be resent forever);
     * - 408, 429, 5xx, 0 (network/timeout) back off;
     * - other 4xx: attempts += 1;
     * - anything else (1xx, unfollowed 3xx) backs off: the server is not answering usefully.
     */
    fun classify(status: Int, batchSize: Int): UploadVerdict = when {
        status in 200..299 -> UploadVerdict.Delivered
        status == 401 || status == 403 -> UploadVerdict.AuthFailed(status)
        status == 413 && batchSize > 1 -> UploadVerdict.Shrink(max(1, batchSize / 2))
        status == 408 || status == 429 || status in 500..599 || status == 0 -> UploadVerdict.RetryLater(status)
        status in 400..499 -> UploadVerdict.Rejected(status)
        else -> UploadVerdict.RetryLater(status)
    }

    /**
     * `min(900, 10 * 2^n)` seconds with +-20 % jitter; n = failures before this one.
     * A `Retry-After` in seconds wins (capped at one day). [random] returns [0, 1).
     */
    fun backoffDelayMs(previousFailures: Int, retryAfter: String?, random: () -> Double): Long {
        parseRetryAfterSec(retryAfter)?.let { return it * 1000 }
        val exp = min(max(previousFailures, 0), 20)
        val baseSec = min(MAX_BACKOFF_SEC, BASE_BACKOFF_SEC shl exp)
        val factor = 0.8 + 0.4 * random().coerceIn(0.0, 1.0)
        return (baseSec * 1000 * factor).toLong()
    }

    /** Only the delta-seconds form; an HTTP-date falls back to the computed backoff. */
    fun parseRetryAfterSec(header: String?): Long? {
        val value = header?.trim()?.toLongOrNull() ?: return null
        if (value < 0) return null
        return min(value, MAX_RETRY_AFTER_SEC)
    }
}

enum class UploadTrigger { RECORD, CONNECTIVITY, SYNC, AUTHORIZATION, WATCHDOG }

/** Upload pacing state; persisted so backoff and auth pauses survive process death. */
data class UploadState(
    val failures: Int = 0,
    val nextAttemptAtMs: Long = 0,
    val lastAttemptAtMs: Long = 0,
    val authPausedUntilMs: Long = 0,
    val authorizationRequired: Boolean = false,
    val lastFailureWasNetwork: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("failures", failures)
        .put("nextAttemptAt", nextAttemptAtMs)
        .put("lastAttemptAt", lastAttemptAtMs)
        .put("authPausedUntil", authPausedUntilMs)
        .put("authorizationRequired", authorizationRequired)
        .put("lastFailureWasNetwork", lastFailureWasNetwork)

    companion object {
        fun fromJson(text: String?): UploadState {
            if (text.isNullOrEmpty()) return UploadState()
            return try {
                val o = JSONObject(text)
                UploadState(
                    failures = (Json.value(o, "failures") as? Number)?.toInt() ?: 0,
                    nextAttemptAtMs = (Json.value(o, "nextAttemptAt") as? Number)?.toLong() ?: 0,
                    lastAttemptAtMs = (Json.value(o, "lastAttemptAt") as? Number)?.toLong() ?: 0,
                    authPausedUntilMs = (Json.value(o, "authPausedUntil") as? Number)?.toLong() ?: 0,
                    authorizationRequired = Json.value(o, "authorizationRequired") == true,
                    lastFailureWasNetwork = Json.value(o, "lastFailureWasNetwork") == true,
                )
            } catch (e: Exception) {
                UploadState()
            }
        }
    }
}

/** When an upload may run, and how the pacing state moves after each outcome. */
object UploadScheduler {
    const val AUTH_PAUSE_MS = 15 * 60_000L

    /**
     * sync() and setAuthorization() always run. Otherwise an auth pause blocks everything; when
     * connectivity returns after a network failure the backoff is skipped (the failure is gone);
     * record inserts and watchdog ticks wait for the backoff and for uploadIntervalSec since the
     * last attempt.
     */
    fun isDue(trigger: UploadTrigger, state: UploadState, nowMs: Long, uploadIntervalSec: Double): Boolean = when (trigger) {
        UploadTrigger.SYNC, UploadTrigger.AUTHORIZATION -> true
        else -> when {
            nowMs < state.authPausedUntilMs -> false
            trigger == UploadTrigger.CONNECTIVITY -> state.lastFailureWasNetwork || nowMs >= state.nextAttemptAtMs
            else -> nowMs >= nextDueAtMs(state, uploadIntervalSec)
        }
    }

    /** Earliest time a RECORD/WATCHDOG trigger would be due. */
    fun nextDueAtMs(state: UploadState, uploadIntervalSec: Double): Long {
        val byInterval = if (uploadIntervalSec > 0) state.lastAttemptAtMs + (uploadIntervalSec * 1000).toLong() else 0
        return maxOf(state.nextAttemptAtMs, byInterval, state.authPausedUntilMs)
    }

    fun attempted(state: UploadState, nowMs: Long) = state.copy(lastAttemptAtMs = nowMs)

    fun delivered(state: UploadState) =
        state.copy(failures = 0, nextAttemptAtMs = 0, authPausedUntilMs = 0, authorizationRequired = false, lastFailureWasNetwork = false)

    fun retryLater(state: UploadState, nowMs: Long, delayMs: Long, networkFailure: Boolean) =
        state.copy(failures = state.failures + 1, nextAttemptAtMs = nowMs + delayMs, lastFailureWasNetwork = networkFailure)

    fun authPaused(state: UploadState, nowMs: Long) =
        state.copy(authorizationRequired = true, authPausedUntilMs = nowMs + AUTH_PAUSE_MS)

    fun authorizationSet(state: UploadState) =
        state.copy(authorizationRequired = false, authPausedUntilMs = 0, failures = 0, nextAttemptAtMs = 0)
}

/** The optional `long_ping` object in a 2xx upload response. [reset] clears the server's overrides (before [config]). */
data class RemoteDirective(val config: JSONObject?, val stop: Boolean, val reset: Boolean = false) {
    companion object {
        fun parse(body: String?): RemoteDirective? {
            val text = body?.trim() ?: return null
            if (!text.startsWith("{")) return null
            val root = try {
                JSONObject(text)
            } catch (e: Exception) {
                return null
            }
            val lp = Json.value(root, "long_ping") as? JSONObject ?: return null
            return RemoteDirective(
                config = Json.value(lp, "config") as? JSONObject,
                stop = Json.value(lp, "stop") == true,
                reset = Json.value(lp, "reset") == true,
            )
        }
    }
}
