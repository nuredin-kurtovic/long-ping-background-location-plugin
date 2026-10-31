package com.longping.core

import org.json.JSONObject

/** DESIGN.md, "Lifecycle and recovery": the engine state that survives process death. */
data class EngineState(
    val enabled: Boolean = false,
    val isMoving: Boolean = false,
    val anchor: GeoPoint? = null,
    val parkedAt: GeoPoint? = null,
    val lastRecordedTimeMs: Long? = null,
    val lastFixTimeMs: Long? = null,
) {
    val motion: MotionState get() = MotionState(isMoving, anchor, parkedAt)

    fun withMotion(m: MotionState) = copy(isMoving = m.isMoving, anchor = m.anchor, parkedAt = m.parkedAt)

    fun toJson(): JSONObject = JSONObject()
        .put("enabled", enabled)
        .put("isMoving", isMoving)
        .put("anchor", anchor?.toJson() ?: JSONObject.NULL)
        .put("parkedAt", parkedAt?.toJson() ?: JSONObject.NULL)
        .put("lastRecordedTime", lastRecordedTimeMs ?: JSONObject.NULL)
        .put("lastFixTime", lastFixTimeMs ?: JSONObject.NULL)

    companion object {
        /** Unreadable state restores as stopped: never start tracking from garbage. */
        fun fromJson(text: String?): EngineState {
            if (text.isNullOrEmpty()) return EngineState()
            return try {
                val o = JSONObject(text)
                EngineState(
                    enabled = Json.value(o, "enabled") == true,
                    isMoving = Json.value(o, "isMoving") == true,
                    anchor = GeoPoint.fromJson(Json.value(o, "anchor") as? JSONObject),
                    parkedAt = GeoPoint.fromJson(Json.value(o, "parkedAt") as? JSONObject),
                    lastRecordedTimeMs = (Json.value(o, "lastRecordedTime") as? Number)?.toLong(),
                    lastFixTimeMs = (Json.value(o, "lastFixTime") as? Number)?.toLong(),
                )
            } catch (e: Exception) {
                EngineState()
            }
        }
    }
}
