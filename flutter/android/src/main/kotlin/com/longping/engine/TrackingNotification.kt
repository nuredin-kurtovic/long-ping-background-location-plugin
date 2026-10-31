package com.longping.engine

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.drawable.AdaptiveIconDrawable
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.longping.core.LongPingConfig
import com.longping.core.NotificationPriority

/** The foreground-service notification, built from config.notification. */
internal class TrackingNotification(private val context: Context) {
    private val manager: NotificationManager? get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    fun build(config: LongPingConfig, text: String): Notification {
        val n = config.notification
        val channel = ensureChannel(n.channelName, n.priority)
        return NotificationCompat.Builder(context, channel)
            .setContentTitle(n.title)
            .setContentText(text)
            .setSmallIcon(smallIcon(n.smallIcon))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(compatPriority(n.priority))
            .apply { contentIntent()?.let { setContentIntent(it) } }
            .build()
    }

    /** Re-posts the running service's notification. Never throws (POST_NOTIFICATIONS may be denied on 13+). */
    fun post(notification: Notification) {
        try {
            manager?.notify(ID, notification)
        } catch (e: Exception) {
            // The service keeps running; only the text update is lost.
        }
    }

    /**
     * Channel importance is fixed once created (the user owns it after that), so each priority
     * gets its own channel id; the others are deleted so the app's settings stay tidy.
     */
    private fun ensureChannel(name: String, priority: NotificationPriority): String {
        val id = CHANNEL_PREFIX + priority.wire
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return id
        val nm = manager ?: return id
        try {
            val importance = when (priority) {
                NotificationPriority.LOW -> NotificationManager.IMPORTANCE_LOW
                NotificationPriority.DEFAULT -> NotificationManager.IMPORTANCE_DEFAULT
                NotificationPriority.HIGH -> NotificationManager.IMPORTANCE_HIGH
            }
            nm.createNotificationChannel(NotificationChannel(id, name, importance).apply { setShowBadge(false) })
            NotificationPriority.entries.filter { it != priority }.forEach { nm.deleteNotificationChannel(CHANNEL_PREFIX + it.wire) }
        } catch (e: Exception) {
            // A broken NotificationManager must not stop tracking; startForeground reports real failures.
        }
        return id
    }

    private fun smallIcon(name: String?): Int {
        val id = name?.let { configuredIcon(it) } ?: context.applicationInfo.icon.takeIf { it != 0 }
        // Android 8.0 crashes the app ("Bad notification posted: Couldn't create icon") when the
        // small icon is an adaptive launcher icon, which the default app icon usually is.
        if (id == null || (Build.VERSION.SDK_INT == Build.VERSION_CODES.O && isAdaptive(id))) return FALLBACK_ICON
        return id
    }

    private fun configuredIcon(name: String): Int? {
        for (type in arrayOf("drawable", "mipmap")) {
            // Resource names come from JS config, so only a runtime lookup can find them.
            @Suppress("DiscouragedApi")
            val id = context.resources.getIdentifier(name, type, context.packageName)
            if (id != 0) return id
        }
        return null
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun isAdaptive(id: Int): Boolean = try {
        ContextCompat.getDrawable(context, id) is AdaptiveIconDrawable
    } catch (e: Exception) {
        true
    }

    private fun contentIntent(): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        return PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun compatPriority(p: NotificationPriority) = when (p) {
        NotificationPriority.LOW -> NotificationCompat.PRIORITY_LOW
        NotificationPriority.DEFAULT -> NotificationCompat.PRIORITY_DEFAULT
        NotificationPriority.HIGH -> NotificationCompat.PRIORITY_HIGH
    }

    companion object {
        const val ID = 0x4C50
        const val CHANNEL_PREFIX = "longping_tracking_"
        val FALLBACK_ICON = android.R.drawable.ic_menu_mylocation
    }
}
