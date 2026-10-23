package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.AppNotification
import kotlinx.coroutines.delay
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.time.Instant

/** iOS NotificationsRepository (Models/Notifications.swift). */
interface NotificationsRepository {
    suspend fun notifications(): List<AppNotification>
    suspend fun unreadCount(): Int
    suspend fun markAllRead()
    /** Idempotent: the phone hands the token back on every launch. [platform]
     *  is `device_tokens.platform`: "android" here, "ios" on the iPhone. */
    suspend fun register(deviceToken: String, platform: String)
    /** On sign-out. A token left attached to whoever registered it puts their
     *  commissions on the next person's lock screen. */
    suspend fun forgetDevices()
}

fun Dependencies.notifications(): NotificationsRepository =
    if (isDemo) DemoNotificationsRepository else SupabaseNotificationsRepository(requireClient())

/** Reads `notification_feed`, which renders the title and body in SQL. */
class SupabaseNotificationsRepository(private val client: SupabaseClient) : NotificationsRepository {
    override suspend fun notifications(): List<AppNotification> =
        client.decode(client.select("notification_feed", "order=created_at.desc&limit=50"))

    override suspend fun unreadCount(): Int = client.rpc("unread_notification_count").jsonPrimitive.intOrNull ?: 0

    override suspend fun markAllRead() = client.rpcVoid("mark_notifications_read")

    override suspend fun register(deviceToken: String, platform: String) =
        client.rpcVoid("register_device_token", buildJsonObject {
            put("p_token", deviceToken)
            put("p_platform", platform)
        })

    override suspend fun forgetDevices() = client.rpcVoid("forget_my_device_tokens")
}

/** Demo notifications that clear when opened, so the badge behaves (iOS
 *  PreviewNotificationsRepository). Each one leads somewhere: the message to
 *  the demo's support conversation. */
object DemoNotificationsRepository : NotificationsRepository {
    const val demoRecommendationId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"  // DemoSamples: the finished lead
    const val demoInvoiceId = "dddddddd-dddd-dddd-dddd-dddddddddddd"  // DemoSamples.invoiceId

    @Volatile private var readAll = false
    private val created = Instant.now()

    override suspend fun notifications(): List<AppNotification> {
        delay(80)
        val read = if (readAll) Instant.now() else null
        return listOf(
            AppNotification("dddddddd-0000-0000-0000-000000000002", "message_received", "Pierre-Louis Tettamanti",
                "Je vous réponds tout de suite.", threadId = DemoChatStore.supportThread,
                readAt = read, createdAt = created.minusSeconds(600)),
            AppNotification("dddddddd-0000-0000-0000-000000000001", "reward_earned", "Commission acquise",
                "Thomas Dubois a signé — 300,00 €", recommendationId = demoRecommendationId,
                readAt = read, createdAt = created.minusSeconds(1800)),
            AppNotification("dddddddd-0000-0000-0000-000000000003", "invoice_ready", "Facture à signer",
                "Facture FA-2026-0001 — 300,00 €", invoiceId = demoInvoiceId, recommendationId = demoRecommendationId,
                readAt = created.minusSeconds(86_000), createdAt = created.minusSeconds(86_400)),
        )
    }

    override suspend fun unreadCount(): Int = if (readAll) 0 else 2
    override suspend fun markAllRead() { readAll = true }
    override suspend fun register(deviceToken: String, platform: String) {}
    override suspend fun forgetDevices() {}
}
