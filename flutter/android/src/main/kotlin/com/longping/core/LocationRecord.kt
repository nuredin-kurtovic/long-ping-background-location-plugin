package com.longping.core

import org.json.JSONObject

/** DESIGN.md, "Location record": the one JSON shape that is emitted, stored and uploaded. */
object LocationRecord {
    fun build(
        uuid: String,
        fix: Fix,
        event: RecordEvent,
        isMoving: Boolean,
        battery: BatteryState,
        extras: JSONObject?,
    ): JSONObject {
        val coords = JSONObject()
            .put("latitude", fix.latitude)
            .put("longitude", fix.longitude)
            .put("accuracy", finiteOr(fix.accuracy, -1.0))
            .put("speed", finiteOr(fix.speed, -1.0))
            .put("heading", finiteOr(fix.heading, -1.0))
            .put("altitude", fix.altitude?.takeIf { it.isFinite() } ?: JSONObject.NULL)
        val record = JSONObject()
            .put("uuid", uuid)
            .put("timestamp", Iso8601.format(fix.timeMs))
            .put("event", event.wire)
            .put("is_moving", isMoving)
            .put("coords", coords)
            .put("battery", JSONObject().put("level", finiteOr(battery.level, -1.0)).put("is_charging", battery.isCharging))
            .put("mock", fix.mock)
        if (extras != null && extras.length() > 0) record.put("extras", Json.copy(extras))
        return record
    }

    /** config.http.extras overlaid with per-call extras (per-call keys win); null when both are empty. */
    fun mergeExtras(configExtras: JSONObject, callExtras: JSONObject?): JSONObject? {
        val merged = Json.copy(configExtras)
        if (callExtras != null) for (key in Json.keys(callExtras)) merged.put(key, callExtras.opt(key))
        return merged.takeIf { it.length() > 0 }
    }

    /** Fixed record used to validate location templates at configure time. */
    fun sample(): JSONObject = build(
        uuid = "00000000-0000-4000-8000-000000000000",
        fix = Fix(
            latitude = 43.85,
            longitude = 18.41,
            accuracy = 4.8,
            speed = 12.3,
            heading = 181.0,
            altitude = 520.4,
            timeMs = 1_792_929_600_123L,
            mock = false,
        ),
        event = RecordEvent.INTERVAL,
        isMoving = true,
        battery = BatteryState(0.82, false),
        extras = JSONObject().put("sample", true),
    )

    private fun finiteOr(value: Double, fallback: Double) = if (value.isFinite()) value else fallback
}

/**
 * DESIGN.md, upload templates: `{{token}}` is replaced by the raw JSON value; strings go in
 * without quotes (the template author writes them), `extras` is JSON object text.
 */
object LocationTemplate {
    val TOKENS: Set<String> = linkedSetOf(
        "uuid", "timestamp", "event", "is_moving", "latitude", "longitude", "accuracy", "speed", "heading",
        "altitude", "battery_level", "battery_is_charging", "mock", "extras",
    )

    private val TOKEN = Regex("""\{\{\s*([^{}\s]*)\s*\}\}""")

    fun unknownTokens(template: String): List<String> =
        TOKEN.findAll(template).map { it.groupValues[1] }.filter { it !in TOKENS }.distinct().toList()

    fun render(template: String, record: JSONObject): String {
        val coords = record.opt("coords") as? JSONObject ?: JSONObject()
        val battery = record.opt("battery") as? JSONObject ?: JSONObject()
        return TOKEN.replace(template) { match ->
            when (match.groupValues[1]) {
                "uuid" -> raw(record.opt("uuid"))
                "timestamp" -> raw(record.opt("timestamp"))
                "event" -> raw(record.opt("event"))
                "is_moving" -> raw(record.opt("is_moving"))
                "latitude" -> raw(coords.opt("latitude"))
                "longitude" -> raw(coords.opt("longitude"))
                "accuracy" -> raw(coords.opt("accuracy"))
                "speed" -> raw(coords.opt("speed"))
                "heading" -> raw(coords.opt("heading"))
                "altitude" -> raw(coords.opt("altitude"))
                "battery_level" -> raw(battery.opt("level"))
                "battery_is_charging" -> raw(battery.opt("is_charging"))
                "mock" -> raw(record.opt("mock"))
                "extras" -> (record.opt("extras") as? JSONObject)?.toString() ?: "{}"
                else -> match.value
            }
        }
    }

    /**
     * null when [template] only uses known tokens and renders (for a sample record) to strict JSON;
     * otherwise the reason. [requireObject]: the result must be a JSON object (rootProperty '.').
     */
    fun validate(template: String, requireObject: Boolean): String? {
        val unknown = unknownTokens(template)
        if (unknown.isNotEmpty()) return "unknown token ${unknown.joinToString { "{{$it}}" }}"
        val rendered = render(template, LocationRecord.sample())
        StrictJson.validate(rendered)?.let { return "does not render valid JSON ($it): $rendered" }
        if (requireObject && !rendered.trimStart().startsWith("{")) return "must render a JSON object when rootProperty is '.'"
        return null
    }

    private fun raw(value: Any?): String = if (value is String) value else Json.valueText(value)
}
