package com.longping.core

import org.json.JSONObject
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * One position from the OS, already normalised: unknown accuracy / speed / heading are -1,
 * unknown altitude is null, [timeMs] is the fix time (UTC epoch ms).
 */
data class Fix(
    val latitude: Double,
    val longitude: Double,
    val accuracy: Double,
    val speed: Double = -1.0,
    val heading: Double = -1.0,
    val altitude: Double? = null,
    val timeMs: Long,
    val mock: Boolean = false,
) {
    val hasAccuracy: Boolean get() = accuracy >= 0

    fun toPoint() = GeoPoint(latitude, longitude, accuracy, timeMs)
}

/** level 0..1 (-1 unknown). */
data class BatteryState(val level: Double, val isCharging: Boolean) {
    companion object {
        val UNKNOWN = BatteryState(-1.0, false)

        /** From Android's BatteryManager extras; scale <= 0 or level < 0 means unknown. */
        fun fromRaw(level: Int, scale: Int, isCharging: Boolean): BatteryState =
            if (level < 0 || scale <= 0) BatteryState(-1.0, isCharging)
            else BatteryState(min(1.0, level.toDouble() / scale), isCharging)
    }
}

/** A position kept in persisted engine state (stop-detector anchor / parked point). */
data class GeoPoint(val latitude: Double, val longitude: Double, val accuracy: Double, val timeMs: Long) {
    fun toJson(): JSONObject = JSONObject()
        .put("latitude", latitude)
        .put("longitude", longitude)
        .put("accuracy", accuracy)
        .put("time", timeMs)

    companion object {
        fun fromJson(obj: JSONObject?): GeoPoint? {
            if (obj == null) return null
            val lat = Json.value(obj, "latitude") as? Number ?: return null
            val lon = Json.value(obj, "longitude") as? Number ?: return null
            val acc = Json.value(obj, "accuracy") as? Number ?: return null
            val time = Json.value(obj, "time") as? Number ?: return null
            return GeoPoint(lat.toDouble(), lon.toDouble(), acc.toDouble(), time.toLong())
        }
    }
}

object Geo {
    const val EARTH_RADIUS_M = 6_371_008.8

    /** Great-circle (haversine) distance in meters. */
    fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * EARTH_RADIUS_M * atan2(sqrt(a), sqrt(max(0.0, 1 - a)))
    }

    fun distanceM(a: GeoPoint, b: GeoPoint): Double = distanceM(a.latitude, a.longitude, b.latitude, b.longitude)
}
