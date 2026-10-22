package com.trinityenergie.energycourtage.push

import com.trinityenergie.energycourtage.model.Route

/**
 * Where a push leads, from the ids it carries -- the pure half of
 * [Push.routeFrom], so it can be tested without Android.
 *
 * send-push puts `thread_id`, `recommendation_id` and `invoice_id` in the FCM
 * message's `data`. They reach the app under the same keys whichever way the
 * notification was shown: as extras of the launch intent when the system drew
 * it (the app was in the background), or as the extras of the PendingIntent
 * [TrinityMessagingService] builds (the app was open).
 */
object PushRoute {
    const val THREAD_ID = "thread_id"
    const val RECOMMENDATION_ID = "recommendation_id"
    const val INVOICE_ID = "invoice_id"
    const val KIND = "kind"
    const val NOTIFICATION_ID = "notification_id"

    val routeKeys = listOf(THREAD_ID, RECOMMENDATION_ID, INVOICE_ID)

    private val uuid = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    /** An id only if it is one: anything else is ignored, as iOS's UUID(uuidString:) does. */
    private fun id(value: String?): String? = value?.trim()?.takeIf { uuid.matches(it) }?.lowercase()

    /** The most specific route the data names (an invoice also names its recommendation), or null. */
    fun parse(data: Map<String, String?>): Route? = Route.from(
        threadId = id(data[THREAD_ID]),
        recommendationId = id(data[RECOMMENDATION_ID]),
        invoiceId = id(data[INVOICE_ID]),
    )

    /** The tag a notification is shown under: the same one send-push gives FCM, so a retry replaces it. */
    fun tag(notificationId: String?): String? = notificationId?.takeIf { it.isNotBlank() }?.let { "n-$it" }
}
