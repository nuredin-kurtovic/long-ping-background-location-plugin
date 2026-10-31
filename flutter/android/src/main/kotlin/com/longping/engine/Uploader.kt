package com.longping.engine

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import com.longping.core.AuthCredentials
import com.longping.core.Clock
import com.longping.core.LongPingConfig
import com.longping.core.RemoteDirective
import com.longping.core.UploadBody
import com.longping.core.UploadPolicy
import com.longping.core.UploadScheduler
import com.longping.core.UploadState
import com.longping.core.UploadTrigger
import com.longping.core.UploadVerdict
import org.json.JSONObject
import java.net.URL
import java.util.Random
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * DESIGN.md, "Upload": one upload at a time on a dedicated thread; uploads continue while
 * tracking is stopped until the queue is empty. Decisions come from core (UploadScheduler,
 * UploadPolicy); this class does I/O and bookkeeping only.
 */
internal class Uploader(
    context: Context,
    private val queue: QueueStore,
    private val auth: AuthStore,
    private val prefs: EnginePrefs,
    private val log: Logger,
    private val clock: Clock,
    private val host: Host,
    private val transport: HttpTransport = HttpTransport(),
) {
    interface Host {
        val config: LongPingConfig
        fun emit(event: String, payload: JSONObject)
        fun onRemoteDirective(directive: RemoteDirective)
    }

    private val thread = HandlerThread("LongPing-upload").apply { start() }
    private val handler = Handler(thread.looper)
    private val random = Random()
    private val wakeLock: PowerManager.WakeLock? =
        (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LongPing:upload")
            ?.apply { setReferenceCounted(false) }
    private val wakeupToken = Any()

    @Volatile
    var state: UploadState = UploadState.fromJson(prefs.upload)
        private set
    private val stateLock = Any()

    val authorizationRequired: Boolean get() = state.authorizationRequired

    fun trigger(trigger: UploadTrigger, done: ((Int) -> Unit)? = null) {
        handler.post {
            val uploaded = runIfDue(trigger)
            done?.invoke(uploaded)
        }
    }

    /**
     * setAuthorization(): clear the auth pause and backoff now (so getState() right after reports
     * authorizationRequired = false even while an upload is in flight), then upload.
     */
    fun authorizationChanged() {
        update { UploadScheduler.authorizationSet(it) }
        handler.post { runIfDue(UploadTrigger.AUTHORIZATION) }
    }

    /** For the WorkManager watchdog: run once and wait (bounded) for the result. */
    fun runBlocking(trigger: UploadTrigger, timeoutMs: Long): Int {
        val result = AtomicInteger(0)
        val latch = CountDownLatch(1)
        trigger(trigger) { n ->
            result.set(n)
            latch.countDown()
        }
        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return result.get()
    }

    private fun runIfDue(trigger: UploadTrigger): Int {
        val config = host.config
        if (!config.http.uploadsEnabled) return 0
        return try {
            if (queue.count() == 0L) return 0
            if (!UploadScheduler.isDue(trigger, state, clock.nowMs(), config.http.uploadIntervalSec)) {
                scheduleWakeup(config)
                return 0
            }
            drain()
        } catch (e: Exception) {
            log.error(TAG, "upload run failed", e)
            0
        } finally {
            wakeLock?.let { if (it.isHeld) it.release() }
        }
    }

    private fun drain(): Int {
        var uploaded = 0
        var limitOverride: Int? = null // 413 halving lasts for the rest of this run
        var refreshed = false
        var credentialRetries = 0
        while (true) {
            val config = host.config
            val http = config.http
            if (!http.uploadsEnabled) break
            val limit = limitOverride ?: if (http.batch) http.maxBatchSize else 1
            val rows = queue.oldest(limit)
            if (rows.isEmpty()) break

            val texts = ArrayList<String>(rows.size)
            val sendable = ArrayList<QueueStore.Row>(rows.size)
            for (row in rows) {
                try {
                    texts.add(UploadBody.recordText(row.json, http.locationTemplate))
                    sendable.add(row)
                } catch (e: Exception) {
                    queue.delete(listOf(row.id))
                    log.error(TAG, "dropped unreadable record ${row.uuid}", e)
                }
            }
            if (sendable.isEmpty()) continue

            val params = http.params()
            val body = if (http.batch) UploadBody.batch(texts, params, http.rootProperty) else UploadBody.single(texts[0], params, http.rootProperty)
            val credentials = auth.get()
            val ids = sendable.map { it.id }

            wakeLock?.acquire(WAKE_LOCK_MS)
            update { UploadScheduler.attempted(it, clock.nowMs()) }
            val started = clock.nowMs()
            val response = transport.send(http.url!!, http.method.wire, headers(http.headers, credentials), body, (http.timeoutSec * 1000).toInt())
            report(response, sendable.size, http.method.wire, http.url, clock.nowMs() - started)

            when (val verdict = UploadPolicy.classify(response.status, sendable.size)) {
                UploadVerdict.Delivered -> {
                    queue.delete(ids)
                    uploaded += ids.size
                    update { UploadScheduler.delivered(it) }
                    RemoteDirective.parse(response.body)?.let { host.onRemoteDirective(it) }
                }
                is UploadVerdict.AuthFailed -> {
                    // setAuthorization() ran while this request was in flight: retry with the new token.
                    if (auth.get() != credentials && credentialRetries++ < 2) continue
                    if (credentials != null && credentials.canRefresh && !refreshed) {
                        refreshed = true
                        val failure = refresh(credentials, http.timeoutSec) ?: continue // refreshed: retry the same records once
                        pauseForAuth(verdict.status, failure, credentials)
                        break
                    }
                    val error = if (refreshed) "rejected after token refresh (HTTP ${verdict.status})" else "HTTP ${verdict.status}"
                    pauseForAuth(verdict.status, error, credentials)
                    break
                }
                is UploadVerdict.Shrink -> {
                    limitOverride = verdict.batchSize
                    log.warn(TAG, "HTTP 413: retrying with ${verdict.batchSize} records per request")
                }
                is UploadVerdict.RetryLater -> {
                    val delay = UploadPolicy.backoffDelayMs(state.failures, response.retryAfter) { random.nextDouble() }
                    update { UploadScheduler.retryLater(it, clock.nowMs(), delay, networkFailure = response.status == 0) }
                    // The next automatic attempt also waits for uploadIntervalSec; log when it really happens.
                    val nextInSec = (UploadScheduler.nextDueAtMs(state, config.http.uploadIntervalSec) - clock.nowMs()).coerceAtLeast(0) / 1000
                    log.warn(TAG, "upload failed (${statusText(response)}); records kept; backoff ${delay / 1000} s, next attempt in $nextInSec s")
                    scheduleWakeup(config)
                    break
                }
                is UploadVerdict.Rejected -> {
                    queue.incrementAttempts(ids)
                    val dropped = queue.dropExhausted(UploadPolicy.MAX_ATTEMPTS)
                    if (dropped.isNotEmpty()) {
                        log.error(TAG, "dropped ${dropped.size} records after ${UploadPolicy.MAX_ATTEMPTS} rejected attempts (HTTP ${verdict.status}): ${dropped.joinToString()}")
                    }
                    break // retried at the normal pace (next record or watchdog tick)
                }
            }
        }
        return uploaded
    }

    /** Config headers, then `Authorization: Bearer` from stored auth (it wins over a configured one). */
    private fun headers(configured: Map<String, String>, credentials: AuthCredentials?): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        configured.forEach { (k, v) -> if (credentials == null || !k.equals("Authorization", ignoreCase = true)) out[k] = v }
        if (credentials != null) out["Authorization"] = "Bearer ${credentials.accessToken}"
        return out
    }

    /**
     * Null when new tokens are stored, else the `authorization` event's error, worded as on iOS:
     * "token refresh failed: HTTP <status>" or "token refresh failed: <network error>".
     */
    private fun refresh(credentials: AuthCredentials, timeoutSec: Double): String? {
        val url = credentials.refreshUrl ?: return "no refresh URL"
        val response = transport.send(url, "POST", credentials.refreshHeaders, credentials.refreshBody(), (timeoutSec * 1000).toInt())
        val tokens = if (response.ok) AuthCredentials.parseRefreshResponse(response.body) else null
        if (tokens == null) {
            val failure = "token refresh failed: ${if (response.status == 0) response.error ?: "network error" else "HTTP ${response.status}"}"
            log.warn(TAG, failure)
            return failure
        }
        if (!auth.replaceIf(credentials, credentials.withTokens(tokens.first, tokens.second))) {
            log.info(TAG, "token refreshed, but the app replaced the authorization meanwhile; using the app's")
            return null
        }
        log.info(TAG, "access token refreshed")
        return null
    }

    /** [error] is the `authorization` event's text (same on both platforms); the log also says why no refresh ran. */
    private fun pauseForAuth(status: Int, error: String, credentials: AuthCredentials?) {
        val reason = when {
            credentials == null -> "no authorization stored"
            !credentials.canRefresh -> "no refreshUrl to renew the token"
            else -> error
        }
        update { UploadScheduler.authPaused(it, clock.nowMs()) }
        log.warn(TAG, "HTTP $status: uploads paused for 15 min or until setAuthorization() ($reason)")
        host.emit("authorization", JSONObject().put("status", status).put("error", error))
    }

    private fun report(r: HttpTransport.Response, count: Int, method: String, url: String?, elapsedMs: Long) {
        val text = r.body.ifEmpty { r.error ?: "" }
        host.emit(
            "http",
            JSONObject()
                .put("status", r.status)
                .put("ok", r.ok)
                .put("count", count)
                .put("responseText", if (text.length > RESPONSE_TEXT_CHARS) text.substring(0, RESPONSE_TEXT_CHARS) else text),
        )
        val line = "$method ${redact(url)} -> ${statusText(r)}, $count records, $elapsedMs ms"
        if (r.ok) log.info(TAG, line) else log.warn(TAG, line)
    }

    private fun scheduleWakeup(config: LongPingConfig) {
        handler.removeCallbacksAndMessages(wakeupToken)
        val delay = UploadScheduler.nextDueAtMs(state, config.http.uploadIntervalSec) - clock.nowMs()
        if (delay > 0) handler.postAtTime({ runIfDue(UploadTrigger.WATCHDOG) }, wakeupToken, android.os.SystemClock.uptimeMillis() + delay)
    }

    private fun update(transform: (UploadState) -> UploadState) {
        synchronized(stateLock) {
            val next = transform(state)
            state = next
            prefs.saveUpload(next.toJson().toString())
        }
    }

    private fun statusText(r: HttpTransport.Response) = if (r.status == 0) "network error: ${r.error}" else "HTTP ${r.status}"

    // Query strings often carry API keys; the log keeps scheme, host and path only.
    private fun redact(url: String?): String = try {
        val u = URL(url)
        "${u.protocol}://${u.host}${if (u.port > 0) ":${u.port}" else ""}${u.path}"
    } catch (e: Exception) {
        "(invalid url)"
    }

    private companion object {
        const val TAG = "http"
        const val WAKE_LOCK_MS = 60_000L
        const val RESPONSE_TEXT_CHARS = 2048
    }
}
