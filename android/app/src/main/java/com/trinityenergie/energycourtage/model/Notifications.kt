package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.time.Instant

/** A row of `notification_feed`. The title and body are rendered by the
 *  database, so the banner a push shows and the row in the list cannot say
 *  different things (iOS AppNotification). */
@Serializable
data class AppNotification(
    val id: String,
    val kind: String = "",
    val title: String = "",
    val body: String = "",
    /** What to open when the row is tapped. */
    val threadId: String? = null,
    val recommendationId: String? = null,
    val invoiceId: String? = null,
    @Serializable(InstantSerializer::class) val readAt: Instant? = null,
    @Serializable(InstantSerializer::class) val createdAt: Instant,
) {
    val isUnread: Boolean get() = readAt == null

    /** The most specific target wins: an invoice notification also names its
     *  recommendation. */
    val route: Route? get() = Route.from(threadId = threadId, recommendationId = recommendationId, invoiceId = invoiceId)
}
