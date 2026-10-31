package com.longping.engine

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** One blocking JSON request. Never throws: network failures come back as status 0. */
internal class HttpTransport {
    data class Response(val status: Int, val body: String, val retryAfter: String?, val error: String?) {
        val ok: Boolean get() = status in 200..299
    }

    fun send(url: String, method: String, headers: Map<String, String>, body: String, timeoutMs: Int): Response {
        var conn: HttpURLConnection? = null
        return try {
            val bytes = body.toByteArray(Charsets.UTF_8)
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                doOutput = true
                useCaches = false
                setFixedLengthStreamingMode(bytes.size)
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("Accept", "application/json")
                headers.forEach { (k, v) -> setRequestProperty(k, v) }
            }
            conn.outputStream.use { it.write(bytes) }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            Response(status, stream?.use { readCapped(it) } ?: "", conn.getHeaderField("Retry-After"), null)
        } catch (e: Exception) {
            // IOException (DNS, refused, timeout, TLS, cleartext blocked by network security config) and
            // IllegalArgumentException from malformed header values all mean "not delivered".
            Response(0, "", null, "${e.javaClass.simpleName}: ${e.message}")
        } finally {
            conn?.disconnect()
        }
    }

    private fun readCapped(input: InputStream): String {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (out.size() < MAX_BODY_BYTES) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, minOf(n, MAX_BODY_BYTES - out.size()))
        }
        return String(out.toByteArray(), Charsets.UTF_8)
    }

    companion object {
        const val MAX_BODY_BYTES = 1 shl 20
    }
}
