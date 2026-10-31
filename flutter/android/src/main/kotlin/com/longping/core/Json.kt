package com.longping.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * org.json helpers that behave the same on Android's org.json and the JVM artifact used by the
 * core tests (their optString/optJSONObject differ on JSON null, so core avoids those).
 */
object Json {
    fun isNull(value: Any?): Boolean = value == null || value == JSONObject.NULL

    /** The value at [key], with JSON null mapped to Kotlin null. */
    fun value(obj: JSONObject, key: String): Any? = obj.opt(key).takeUnless { isNull(it) }

    fun keys(obj: JSONObject): List<String> {
        val out = ArrayList<String>(obj.length())
        val it = obj.keys()
        while (it.hasNext()) out.add(it.next())
        return out
    }

    fun copy(obj: JSONObject): JSONObject = JSONObject(obj.toString())

    /**
     * Deep merge: objects merge key by key, everything else (arrays, scalars, null) in [overlay]
     * replaces what is in [base]. Neither input is modified.
     */
    fun deepMerge(base: JSONObject, overlay: JSONObject): JSONObject {
        val out = copy(base)
        for (key in keys(overlay)) {
            val incoming = overlay.opt(key)
            val existing = out.opt(key)
            val merged = when {
                incoming is JSONObject && existing is JSONObject -> deepMerge(existing, incoming)
                incoming is JSONObject -> copy(incoming)
                incoming is JSONArray -> JSONArray(incoming.toString())
                incoming == null -> JSONObject.NULL
                else -> incoming
            }
            out.put(key, merged)
        }
        return out
    }

    /** Text for a single JSON value, as it would appear inside a document. */
    fun valueText(value: Any?): String = when {
        isNull(value) -> "null"
        value is String -> JSONObject.quote(value)
        value is Number -> JSONObject.numberToString(value)
        value is Boolean -> value.toString()
        else -> value.toString()
    }
}

/**
 * Strict RFC 8259 validator. org.json's tokener is lenient (it accepts unquoted strings such as
 * `2026-10-26T12:00:00Z`), so it cannot tell whether a rendered location template is JSON a
 * server will accept.
 */
object StrictJson {
    private const val MAX_DEPTH = 256

    /** null when [text] is exactly one valid JSON value (surrounding whitespace allowed), else why not. */
    fun validate(text: String): String? = try {
        val p = Parser(text)
        p.skipWs()
        p.value(0)
        p.skipWs()
        if (p.pos != text.length) p.fail("unexpected '${text[p.pos]}'")
        null
    } catch (e: Invalid) {
        e.message
    }

    private class Invalid(message: String) : Exception(message)

    private class Parser(private val s: String) {
        var pos = 0

        fun fail(why: String): Nothing = throw Invalid("$why at offset $pos")

        fun skipWs() {
            while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' || s[pos] == '\r')) pos++
        }

        fun value(depth: Int) {
            if (depth > MAX_DEPTH) fail("nesting too deep")
            if (pos >= s.length) fail("unexpected end")
            when (s[pos]) {
                '{' -> obj(depth)
                '[' -> arr(depth)
                '"' -> str()
                't' -> literal("true")
                'f' -> literal("false")
                'n' -> literal("null")
                else -> if (s[pos] == '-' || s[pos] in '0'..'9') num() else fail("unexpected '${s[pos]}'")
            }
        }

        private fun obj(depth: Int) {
            pos++
            skipWs()
            if (peek() == '}') { pos++; return }
            while (true) {
                skipWs()
                if (peek() != '"') fail("expected a quoted key")
                str()
                skipWs()
                if (peek() != ':') fail("expected ':'")
                pos++
                skipWs()
                value(depth + 1)
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    '}' -> { pos++; return }
                    else -> fail("expected ',' or '}'")
                }
            }
        }

        private fun arr(depth: Int) {
            pos++
            skipWs()
            if (peek() == ']') { pos++; return }
            while (true) {
                skipWs()
                value(depth + 1)
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    ']' -> { pos++; return }
                    else -> fail("expected ',' or ']'")
                }
            }
        }

        private fun str() {
            pos++
            while (true) {
                if (pos >= s.length) fail("unterminated string")
                val c = s[pos]
                when {
                    c == '"' -> { pos++; return }
                    c == '\\' -> {
                        pos++
                        when (peek()) {
                            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> pos++
                            'u' -> {
                                pos++
                                repeat(4) {
                                    val h = peek()
                                    if (h == null || !(h in '0'..'9' || h in 'a'..'f' || h in 'A'..'F')) fail("bad \\u escape")
                                    pos++
                                }
                            }
                            else -> fail("bad escape")
                        }
                    }
                    c < ' ' -> fail("control character in string")
                    else -> pos++
                }
            }
        }

        private fun num() {
            if (peek() == '-') pos++
            when (peek()) {
                '0' -> pos++
                in '1'..'9' -> while (peek()?.let { it in '0'..'9' } == true) pos++
                else -> fail("bad number")
            }
            if (peek() == '.') {
                pos++
                if (peek()?.let { it in '0'..'9' } != true) fail("bad number")
                while (peek()?.let { it in '0'..'9' } == true) pos++
            }
            if (peek() == 'e' || peek() == 'E') {
                pos++
                if (peek() == '+' || peek() == '-') pos++
                if (peek()?.let { it in '0'..'9' } != true) fail("bad number")
                while (peek()?.let { it in '0'..'9' } == true) pos++
            }
        }

        private fun literal(word: String) {
            if (!s.startsWith(word, pos)) fail("unexpected '${s[pos]}'")
            pos += word.length
        }

        private fun peek(): Char? = if (pos < s.length) s[pos] else null
    }
}
