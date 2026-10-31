package com.longping.flutter

import com.longping.core.ConfigException
import org.json.JSONArray
import org.json.JSONObject

/**
 * Dart values (StandardMessageCodec) <-> org.json (the engine's currency). Numbers reach the engine as
 * doubles, as they do from React Native, so both bridges hand it identical input. NaN / Infinity cannot be
 * represented in JSON and are rejected as INVALID_CONFIG naming the key.
 */
internal object FlutterJson {
    /** A Dart map argument; null (no argument) is an empty object. */
    fun toJson(value: Any?, path: String = ""): JSONObject {
        val out = JSONObject()
        val map = value as? Map<*, *> ?: return out
        for ((key, item) in map) {
            val name = key.toString()
            out.put(name, toJsonValue(item, path + name))
        }
        return out
    }

    private fun toJsonArray(list: List<*>, path: String): JSONArray {
        val out = JSONArray()
        list.forEachIndexed { i, item -> out.put(toJsonValue(item, "$path[$i]")) }
        return out
    }

    private fun toJsonValue(value: Any?, path: String): Any = when (value) {
        null -> JSONObject.NULL
        is Boolean -> value
        is Number -> finite(value.toDouble(), path)
        is String -> value
        is Map<*, *> -> toJson(value, "$path.")
        is List<*> -> toJsonArray(value, path)
        else -> throw ConfigException(path, "unsupported value of type ${value.javaClass.simpleName}")
    }

    private fun finite(value: Double, key: String): Double {
        if (value.isNaN() || value.isInfinite()) throw ConfigException(key, "must be a finite number")
        return value
    }

    /** Engine result or event payload -> a value StandardMessageCodec can send. Unit (void) is null. */
    fun toFlutter(value: Any?): Any? = when (value) {
        null, JSONObject.NULL, Unit -> null
        is Boolean, is String, is Int, is Long, is Double -> value
        is Number -> value.toDouble()
        is JSONObject -> HashMap<String, Any?>().also { out ->
            val keys = value.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                out[key] = toFlutter(value.opt(key))
            }
        }
        is JSONArray -> ArrayList<Any?>(value.length()).also { out ->
            for (i in 0 until value.length()) out.add(toFlutter(value.opt(i)))
        }
        else -> value.toString()
    }
}
