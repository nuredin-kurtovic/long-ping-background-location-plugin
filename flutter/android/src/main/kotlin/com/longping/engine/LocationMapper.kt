package com.longping.engine

import android.location.Location
import android.os.Build
import com.google.android.gms.location.Priority
import com.longping.core.Accuracy
import com.longping.core.Fix

/** android.location.Location -> core Fix. */
internal object LocationMapper {
    fun toFix(l: Location): Fix = Fix(
        latitude = l.latitude,
        longitude = l.longitude,
        accuracy = if (l.hasAccuracy()) clean(l.accuracy) else -1.0,
        speed = if (l.hasSpeed()) clean(l.speed) else -1.0,
        heading = if (l.hasBearing()) clean(l.bearing) else -1.0,
        altitude = if (l.hasAltitude()) l.altitude else null,
        timeMs = l.time,
        mock = isMock(l),
    )

    fun isMock(l: Location): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) l.isMock else @Suppress("DEPRECATION") l.isFromMockProvider

    fun priority(accuracy: Accuracy): Int = when (accuracy) {
        Accuracy.HIGH -> Priority.PRIORITY_HIGH_ACCURACY
        Accuracy.BALANCED -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
        Accuracy.LOW -> Priority.PRIORITY_LOW_POWER
    }

    // Location stores floats; going through the shortest decimal form keeps 4.8 from becoming 4.800000190734863 in JSON.
    private fun clean(f: Float): Double = f.toString().toDouble()
}
