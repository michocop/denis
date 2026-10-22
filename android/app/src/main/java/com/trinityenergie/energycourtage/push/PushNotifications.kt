package com.trinityenergie.energycourtage.push

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.trinityenergie.energycourtage.MainActivity
import com.trinityenergie.energycourtage.R

/** The notification shade side of push: the channel, and drawing one notification. */
internal object PushNotifications {
    /** The one channel; send-push names it in every message (android.notification.channel_id). */
    const val CHANNEL_GENERAL = "general"

    /** Palette.brandFill (@color/brand_fill), the tint of the icon, as for the system-drawn ones. */
    private const val ACCENT = 0xFF1F5FFF.toInt()

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(CHANNEL_GENERAL, "Notifications", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Messages, factures à signer, avancement de vos recommandations"
            enableVibration(true)
        }
        // idempotent: recreating keeps whatever the person changed in Settings
        manager.createNotificationChannel(channel)
    }

    fun canPost(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    /**
     * Shows one push the system did not draw itself: the app was open, or the
     * message carried data only. Tapped, it opens MainActivity with the route
     * ids as extras, under the keys [Push.routeFrom] reads.
     */
    @SuppressLint("MissingPermission") // canPost() checks it first
    fun show(
        context: Context,
        title: String?,
        body: String?,
        data: Map<String, String>,
        tag: String?,
        channelId: String?,
    ) {
        if (title.isNullOrBlank() && body.isNullOrBlank()) return
        if (!canPost(context)) return
        createChannels(context)

        val intent = Intent(context, MainActivity::class.java).apply {
            // brought to the front if it is there (onNewIntent), started otherwise
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            for (key in PushRoute.routeKeys + PushRoute.KIND + PushRoute.NOTIFICATION_ID) {
                data[key]?.takeIf { it.isNotEmpty() }?.let { putExtra(key, it) }
            }
        }
        // one request code per notification, so two notifications keep their own extras
        val requestCode = (tag ?: data.toString()).hashCode()
        val pending = PendingIntent.getActivity(
            context, requestCode, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = channelId?.takeIf { manager?.getNotificationChannel(it) != null } ?: CHANNEL_GENERAL

        val notification = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_trinity)
            .setColor(ACCENT)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(if (data[PushRoute.KIND] == "message_received") NotificationCompat.CATEGORY_MESSAGE else null)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()

        try {
            // id 0 under the tag, as the system draws FCM's own: the same push
            // shown either way replaces itself
            NotificationManagerCompat.from(context).notify(tag, 0, notification)
        } catch (_: SecurityException) {
            // permission withdrawn between the check and now
        }
    }
}
