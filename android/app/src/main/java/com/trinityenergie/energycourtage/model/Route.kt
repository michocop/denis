package com.trinityenergie.energycourtage.model

/** Where a notification leads -- a tapped push or a row of the in-app list
 *  (iOS NotificationRoute). The most specific id wins: an invoice
 *  notification also names its recommendation. */
sealed interface Route {
    data class Thread(val id: String) : Route
    data class Recommendation(val id: String) : Route
    data class Invoice(val id: String) : Route

    companion object {
        fun from(threadId: String?, recommendationId: String?, invoiceId: String?): Route? = when {
            invoiceId != null -> Invoice(invoiceId)
            threadId != null -> Thread(threadId)
            recommendationId != null -> Recommendation(recommendationId)
            else -> null
        }
    }
}
