package com.longping.core

import org.json.JSONObject
import java.net.URI
import kotlin.math.roundToLong

/**
 * configure / setConfig / remote-config semantics (DESIGN.md, "Config"):
 * - [resolve]: defaults + input (deep), validated and clamped.
 * - [merge]: current + partial (deep: objects merge, arrays and scalars replace).
 *
 * Rules beyond the contract text (see the Android report):
 * - JSON null on a key that is not nullable means "use the default".
 * - '' on a nullable string (licenseKey, http.url, rootProperty, locationTemplate, smallIcon) is null.
 * - Integer keys (maxBatchSize, maxRecords, maxDays, logMaxDays) are rounded, then clamped.
 */
object ConfigResolver {
    class Resolution(val config: LongPingConfig, val unknownKeys: List<String>)

    private val ROOT_KEYS = setOf(
        "licenseKey", "movingIntervalSec", "parkedIntervalSec", "accuracy", "minAccuracyM", "stopTimeoutSec",
        "stopRadiusM", "movingSpeedMps", "disableStopDetection", "lowBattery", "http", "persistence",
        "startOnBoot", "stopOnTerminate", "remoteConfig", "notification", "ios", "logLevel", "logMaxDays", "debug",
    )
    private val HTTP_KEYS = setOf(
        "url", "method", "headers", "batch", "maxBatchSize", "uploadIntervalSec", "rootProperty",
        "locationTemplate", "params", "extras", "timeoutSec",
    )
    private val LOW_BATTERY_KEYS = setOf("belowPct", "intervalSec")
    private val PERSISTENCE_KEYS = setOf("maxRecords", "maxDays")
    private val NOTIFICATION_KEYS = setOf("title", "text", "channelName", "smallIcon", "priority")
    private val IOS_KEYS = setOf("showsBackgroundLocationIndicator", "activityType")

    // RFC 7230 token characters: anything else makes HttpURLConnection throw at send time.
    private val HEADER_NAME = Regex("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")

    fun defaults(): LongPingConfig = LongPingConfig()

    fun resolve(input: JSONObject): Resolution = parse(Json.deepMerge(defaults().toJson(), input))

    fun merge(current: LongPingConfig, partial: JSONObject): Resolution =
        parse(Json.deepMerge(current.toJson(), partial))

    /** Reads a previously persisted config; anything unreadable falls back to defaults. */
    fun restore(persisted: String?): LongPingConfig {
        if (persisted.isNullOrEmpty()) return defaults()
        return try {
            resolve(JSONObject(persisted)).config
        } catch (e: Exception) {
            defaults()
        }
    }

    private fun parse(merged: JSONObject): Resolution {
        val unknown = ArrayList<String>()
        val root = Fields(merged, "", ROOT_KEYS, unknown)
        val d = LongPingConfig()

        val lowBattery = root.obj("lowBattery")?.let { lb ->
            val f = Fields(lb, "lowBattery.", LOW_BATTERY_KEYS, unknown)
            LowBattery(
                belowPct = f.requiredNumber("belowPct").coerceIn(0.0, 100.0),
                intervalSec = f.requiredNumber("intervalSec").coerceIn(1.0, 86_400.0),
            )
        }

        val httpFields = Fields(root.obj("http") ?: JSONObject(), "http.", HTTP_KEYS, unknown)
        val http = parseHttp(httpFields, d.http)

        val pf = Fields(root.obj("persistence") ?: JSONObject(), "persistence.", PERSISTENCE_KEYS, unknown)
        val persistence = PersistenceConfig(
            maxRecords = pf.integer("maxRecords", d.persistence.maxRecords, 1, 1_000_000),
            maxDays = pf.integer("maxDays", d.persistence.maxDays, 1, 365),
        )

        val nf = Fields(root.obj("notification") ?: JSONObject(), "notification.", NOTIFICATION_KEYS, unknown)
        val notification = NotificationConfig(
            title = nf.string("title", d.notification.title),
            text = nf.string("text", d.notification.text),
            channelName = nf.string("channelName", d.notification.channelName),
            smallIcon = nf.nullableString("smallIcon"),
            priority = nf.enumValue("priority", d.notification.priority, NotificationPriority.entries),
        )

        val iosf = Fields(root.obj("ios") ?: JSONObject(), "ios.", IOS_KEYS, unknown)
        val ios = IosConfig(
            showsBackgroundLocationIndicator = iosf.bool("showsBackgroundLocationIndicator", d.ios.showsBackgroundLocationIndicator),
            activityType = iosf.enumValue("activityType", d.ios.activityType, IosActivityType.entries),
        )

        val minAccuracy = root.number("minAccuracyM", d.minAccuracyM)
        if (minAccuracy < 0) throw ConfigException("minAccuracyM", "must be >= 0 (0 accepts any accuracy)")

        val config = LongPingConfig(
            licenseKey = root.nullableString("licenseKey")?.trim()?.takeIf { it.isNotEmpty() },
            movingIntervalSec = root.number("movingIntervalSec", d.movingIntervalSec).coerceIn(1.0, 86_400.0),
            parkedIntervalSec = root.number("parkedIntervalSec", d.parkedIntervalSec).coerceIn(1.0, 86_400.0),
            accuracy = root.enumValue("accuracy", d.accuracy, Accuracy.entries),
            minAccuracyM = minAccuracy,
            stopTimeoutSec = root.number("stopTimeoutSec", d.stopTimeoutSec).coerceIn(30.0, 86_400.0),
            stopRadiusM = root.number("stopRadiusM", d.stopRadiusM).coerceIn(10.0, 10_000.0),
            movingSpeedMps = root.number("movingSpeedMps", d.movingSpeedMps).coerceIn(0.5, 100.0),
            disableStopDetection = root.bool("disableStopDetection", d.disableStopDetection),
            lowBattery = lowBattery,
            http = http,
            persistence = persistence,
            startOnBoot = root.bool("startOnBoot", d.startOnBoot),
            stopOnTerminate = root.bool("stopOnTerminate", d.stopOnTerminate),
            remoteConfig = root.bool("remoteConfig", d.remoteConfig),
            notification = notification,
            ios = ios,
            logLevel = root.enumValue("logLevel", d.logLevel, LogLevel.entries),
            logMaxDays = root.integer("logMaxDays", d.logMaxDays, 1, 30),
            debug = root.bool("debug", d.debug),
        )
        return Resolution(config, unknown)
    }

    private fun parseHttp(f: Fields, d: HttpConfig): HttpConfig {
        val url = f.nullableString("url")?.trim()?.takeIf { it.isNotEmpty() }
        if (url != null) validateUrl(url)

        val headers = LinkedHashMap<String, String>()
        f.obj("headers")?.let { h ->
            for (name in Json.keys(h)) {
                val path = "http.headers.$name"
                if (!HEADER_NAME.matches(name)) throw ConfigException(path, "is not a valid header name")
                val value = Json.value(h, name) as? String ?: throw ConfigException(path, "must be a string")
                if (value.contains('\r') || value.contains('\n')) throw ConfigException(path, "must not contain line breaks")
                headers[name] = value
            }
        }

        val batch = f.bool("batch", d.batch)
        // '.' with batch falls back to 'locations' rather than rejecting: a remote config that only flips
        // batch on must not be refused because of a rootProperty set for single mode.
        val rootProperty = f.nullableString("rootProperty")

        val template = f.nullableString("locationTemplate")
        if (template != null) {
            val error = LocationTemplate.validate(template, requireObject = !batch && rootProperty == ".")
            if (error != null) throw ConfigException("http.locationTemplate", error)
        }

        val methodText = f.string("method", d.method.wire).uppercase()
        val method = HttpMethod.entries.firstOrNull { it.wire == methodText }
            ?: throw ConfigException("http.method", "must be 'POST' or 'PUT'")

        return HttpConfig(
            url = url,
            method = method,
            headers = headers,
            batch = batch,
            maxBatchSize = f.integer("maxBatchSize", d.maxBatchSize, 1, 1000),
            uploadIntervalSec = f.number("uploadIntervalSec", d.uploadIntervalSec).coerceIn(0.0, 86_400.0),
            rootProperty = rootProperty,
            locationTemplate = template,
            paramsJson = (f.obj("params") ?: JSONObject()).toString(),
            extrasJson = (f.obj("extras") ?: JSONObject()).toString(),
            timeoutSec = f.number("timeoutSec", d.timeoutSec).coerceIn(5.0, 120.0),
        )
    }

    private fun validateUrl(url: String) {
        val uri = try {
            URI(url)
        } catch (e: Exception) {
            throw ConfigException("http.url", "is not a valid URL")
        }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") throw ConfigException("http.url", "must start with http:// or https://")
        if (uri.host.isNullOrEmpty()) throw ConfigException("http.url", "has no host")
    }

    /** Typed, path-aware access to one config object; records keys it does not know. */
    private class Fields(
        private val obj: JSONObject,
        private val prefix: String,
        known: Set<String>,
        unknown: MutableList<String>,
    ) {
        init {
            for (key in Json.keys(obj)) if (key !in known) unknown.add(prefix + key)
        }

        private fun path(key: String) = prefix + key

        private fun raw(key: String): Any? = Json.value(obj, key)

        fun number(key: String, default: Double): Double {
            val v = raw(key) ?: return default
            if (v !is Number) throw ConfigException(path(key), "must be a number")
            val d = v.toDouble()
            if (d.isNaN() || d.isInfinite()) throw ConfigException(path(key), "must be a finite number")
            return d
        }

        fun requiredNumber(key: String): Double {
            if (raw(key) == null) throw ConfigException(path(key), "is required")
            return number(key, 0.0)
        }

        fun integer(key: String, default: Int, min: Int, max: Int): Int =
            number(key, default.toDouble()).roundToLong().coerceIn(min.toLong(), max.toLong()).toInt()

        fun bool(key: String, default: Boolean): Boolean {
            val v = raw(key) ?: return default
            return v as? Boolean ?: throw ConfigException(path(key), "must be a boolean")
        }

        fun string(key: String, default: String): String {
            val v = raw(key) ?: return default
            return v as? String ?: throw ConfigException(path(key), "must be a string")
        }

        fun nullableString(key: String): String? {
            val v = raw(key) ?: return null
            val s = v as? String ?: throw ConfigException(path(key), "must be a string or null")
            return s.takeIf { it.isNotEmpty() }
        }

        fun obj(key: String): JSONObject? {
            val v = raw(key) ?: return null
            return v as? JSONObject ?: throw ConfigException(path(key), "must be an object")
        }

        fun <E : WireEnum> enumValue(key: String, default: E, values: List<E>): E {
            val v = raw(key) ?: return default
            val s = v as? String ?: throw ConfigException(path(key), "must be a string")
            return values.firstOrNull { it.wire == s }
                ?: throw ConfigException(path(key), "must be one of ${values.joinToString { "'${it.wire}'" }}")
        }
    }
}
