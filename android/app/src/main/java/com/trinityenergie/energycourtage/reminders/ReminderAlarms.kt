package com.trinityenergie.energycourtage.reminders

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.trinityenergie.energycourtage.R
import org.json.JSONObject
import java.time.Instant

/**
 * Reminders that fire on the phone, with the app closed (the reminder half of
 * iOS Core/LocalNotifications.swift): a server-side reminder mirrored onto
 * the device, so the relance is not something found out the next time one
 * happens to look.
 *
 * An inexact alarm that may run in Doze (setAndAllowWhileIdle): a relance a
 * few minutes late is fine, and it needs no SCHEDULE_EXACT_ALARM. Identified
 * by the reminder's id, so rescheduling replaces rather than duplicates.
 * Alarms do not survive a reboot, so the pending ones are kept in
 * preferences and set again by [ReminderBootReceiver].
 */
object ReminderAlarms {
    const val CHANNEL_ID = "reminders"
    private const val CHANNEL_NAME = "Relances"
    private const val ACTION = "com.trinityenergie.energycourtage.REMINDER"
    const val EXTRA_ID = "reminder_id"
    const val EXTRA_LABEL = "label"
    const val EXTRA_RECOMMENDATION_ID = "recommendation_id"
    private const val PREFS = "reminder_alarms"

    fun schedule(context: Context, reminderId: String, label: String, dueAt: Instant, recommendationId: String? = null) {
        if (!dueAt.isAfter(Instant.now())) return
        ensureChannel(context)
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, dueAt.toEpochMilli(),
            pending(context, reminderId, label, recommendationId))
        prefs(context).edit().putString(reminderId, JSONObject()
            .put("label", label).put("due", dueAt.toEpochMilli()).put("reco", recommendationId ?: "").toString()).apply()
    }

    fun cancel(context: Context, reminderId: String) {
        context.getSystemService(AlarmManager::class.java)?.cancel(pending(context, reminderId, "", null))
        prefs(context).edit().remove(reminderId).apply()
        NotificationManagerCompat.from(context).cancel(reminderId, 0)
    }

    /** After a reboot: every pending relance set again, the past ones dropped. */
    fun restore(context: Context) {
        val now = System.currentTimeMillis()
        prefs(context).all.forEach { (id, raw) ->
            val json = runCatching { JSONObject(raw as String) }.getOrNull() ?: return@forEach
            val due = json.optLong("due")
            if (due <= now) prefs(context).edit().remove(id).apply()
            else schedule(context, id, json.optString("label"), Instant.ofEpochMilli(due), json.optString("reco").ifEmpty { null })
        }
    }

    internal fun fired(context: Context, reminderId: String) { prefs(context).edit().remove(reminderId).apply() }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH))
        }
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun pending(context: Context, reminderId: String, label: String, recommendationId: String?): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java)
            .setAction(ACTION)
            // the data makes each reminder's PendingIntent its own
            .setData(Uri.parse("trinity-reminder://$reminderId"))
            .putExtra(EXTRA_ID, reminderId)
            .putExtra(EXTRA_LABEL, label)
            .putExtra(EXTRA_RECOMMENDATION_ID, recommendationId)
        return PendingIntent.getBroadcast(context, reminderId.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}

/** The alarm going off: the "Relance" notification. Tapping it opens the app
 *  with the recommendation's id in the `recommendation_id` extra. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(ReminderAlarms.EXTRA_ID) ?: return
        val label = intent.getStringExtra(ReminderAlarms.EXTRA_LABEL).orEmpty()
        val recommendationId = intent.getStringExtra(ReminderAlarms.EXTRA_RECOMMENDATION_ID)
        ReminderAlarms.fired(context, id)
        ReminderAlarms.ensureChannel(context)

        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            ?.putExtra(ReminderAlarms.EXTRA_RECOMMENDATION_ID, recommendationId)
        val tap = launch?.let {
            PendingIntent.getActivity(context, id.hashCode(), it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val notification = NotificationCompat.Builder(context, ReminderAlarms.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_reminder)
            .setContentTitle("Relance")
            .setContentText(label)
            .setStyle(NotificationCompat.BigTextStyle().bigText(label))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .apply { if (tap != null) setContentIntent(tap) }
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(id, 0, notification) }
    }
}

/** Alarms are forgotten at shutdown: set the pending relances again. */
class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == "android.intent.action.MY_PACKAGE_REPLACED") {
            ReminderAlarms.restore(context)
        }
    }
}
