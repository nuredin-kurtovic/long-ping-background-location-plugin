package com.longping.core

import org.json.JSONObject

/** A string-valued config enum: [wire] is the exact value used in JSON. */
interface WireEnum {
    val wire: String
}

enum class Accuracy(override val wire: String) : WireEnum {
    HIGH("high"),
    BALANCED("balanced"),
    LOW("low"),
}

enum class LogLevel(override val wire: String, val label: String, private val rank: Int) : WireEnum {
    OFF("off", "OFF", 0),
    ERROR("error", "ERROR", 1),
    WARN("warn", "WARN", 2),
    INFO("info", "INFO", 3),
    DEBUG("debug", "DEBUG", 4),
    ;

    /** Whether a message at [level] is written when this is the configured level. */
    fun allows(level: LogLevel): Boolean = level != OFF && this != OFF && level.rank <= rank
}

enum class HttpMethod(override val wire: String) : WireEnum {
    POST("POST"),
    PUT("PUT"),
}

enum class NotificationPriority(override val wire: String) : WireEnum {
    LOW("low"),
    DEFAULT("default"),
    HIGH("high"),
}

enum class IosActivityType(override val wire: String) : WireEnum {
    AUTOMOTIVE("automotive"),
    OTHER_NAVIGATION("otherNavigation"),
    FITNESS("fitness"),
    OTHER("other"),
}

data class LowBattery(val belowPct: Double, val intervalSec: Double)

data class HttpConfig(
    val url: String? = null,
    val method: HttpMethod = HttpMethod.POST,
    val headers: Map<String, String> = emptyMap(),
    val batch: Boolean = true,
    val maxBatchSize: Int = 100,
    val uploadIntervalSec: Double = 0.0,
    val rootProperty: String? = null,
    val locationTemplate: String? = null,
    /** Canonical JSON text of `params`; kept as text so the config stays immutable and comparable. */
    val paramsJson: String = "{}",
    /** Canonical JSON text of `extras`. */
    val extrasJson: String = "{}",
    val timeoutSec: Double = 30.0,
) {
    val uploadsEnabled: Boolean get() = !url.isNullOrEmpty()

    fun params(): JSONObject = JSONObject(paramsJson)

    fun extras(): JSONObject = JSONObject(extrasJson)
}

data class PersistenceConfig(val maxRecords: Int = 10_000, val maxDays: Int = 7)

data class NotificationConfig(
    val title: String = "Location tracking",
    val text: String = "Sharing your location",
    val channelName: String = "Location tracking",
    val smallIcon: String? = null,
    val priority: NotificationPriority = NotificationPriority.LOW,
)

data class IosConfig(
    val showsBackgroundLocationIndicator: Boolean = false,
    val activityType: IosActivityType = IosActivityType.AUTOMOTIVE,
)

/** The resolved config: every key present, validated and clamped. Defaults match DESIGN.md. */
data class LongPingConfig(
    val movingIntervalSec: Double = 30.0,
    val parkedIntervalSec: Double = 180.0,
    val accuracy: Accuracy = Accuracy.HIGH,
    val minAccuracyM: Double = 100.0,
    val stopTimeoutSec: Double = 300.0,
    val stopRadiusM: Double = 75.0,
    val movingSpeedMps: Double = 3.0,
    val disableStopDetection: Boolean = false,
    val lowBattery: LowBattery? = null,
    val http: HttpConfig = HttpConfig(),
    val persistence: PersistenceConfig = PersistenceConfig(),
    val startOnBoot: Boolean = true,
    val stopOnTerminate: Boolean = false,
    val remoteConfig: Boolean = true,
    val notification: NotificationConfig = NotificationConfig(),
    val ios: IosConfig = IosConfig(),
    val logLevel: LogLevel = LogLevel.INFO,
    val logMaxDays: Int = 3,
    val debug: Boolean = false,
) {
    /** The persisted / reported form: every key, in contract order. */
    fun toJson(): JSONObject = JSONObject().apply {
        put("movingIntervalSec", movingIntervalSec)
        put("parkedIntervalSec", parkedIntervalSec)
        put("accuracy", accuracy.wire)
        put("minAccuracyM", minAccuracyM)
        put("stopTimeoutSec", stopTimeoutSec)
        put("stopRadiusM", stopRadiusM)
        put("movingSpeedMps", movingSpeedMps)
        put("disableStopDetection", disableStopDetection)
        put(
            "lowBattery",
            lowBattery?.let { JSONObject().put("belowPct", it.belowPct).put("intervalSec", it.intervalSec) }
                ?: JSONObject.NULL,
        )
        put("http", JSONObject().apply {
            put("url", http.url ?: JSONObject.NULL)
            put("method", http.method.wire)
            put("headers", JSONObject().also { h -> http.headers.forEach { (k, v) -> h.put(k, v) } })
            put("batch", http.batch)
            put("maxBatchSize", http.maxBatchSize)
            put("uploadIntervalSec", http.uploadIntervalSec)
            put("rootProperty", http.rootProperty ?: JSONObject.NULL)
            put("locationTemplate", http.locationTemplate ?: JSONObject.NULL)
            put("params", http.params())
            put("extras", http.extras())
            put("timeoutSec", http.timeoutSec)
        })
        put("persistence", JSONObject().put("maxRecords", persistence.maxRecords).put("maxDays", persistence.maxDays))
        put("startOnBoot", startOnBoot)
        put("stopOnTerminate", stopOnTerminate)
        put("remoteConfig", remoteConfig)
        put("notification", JSONObject().apply {
            put("title", notification.title)
            put("text", notification.text)
            put("channelName", notification.channelName)
            put("smallIcon", notification.smallIcon ?: JSONObject.NULL)
            put("priority", notification.priority.wire)
        })
        put("ios", JSONObject().apply {
            put("showsBackgroundLocationIndicator", ios.showsBackgroundLocationIndicator)
            put("activityType", ios.activityType.wire)
        })
        put("logLevel", logLevel.wire)
        put("logMaxDays", logMaxDays)
        put("debug", debug)
    }
}
