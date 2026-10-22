package com.trinityenergie.energycourtage.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM's two callbacks.
 *
 * With the app in the background, a send-push message (it carries a
 * `notification`) is drawn by the system on the `general` channel and never
 * reaches [onMessageReceived]; its tap opens MainActivity with the `data` keys
 * as extras. With the app open, or for a data-only message, it lands here and
 * is drawn by [PushNotifications.show] -- shown even with the app open, as on
 * iOS: a message arriving while someone is on Home is exactly when they want it.
 */
class TrinityMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        Push.tokenReceived(applicationContext, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val shown = message.notification
        PushNotifications.show(
            context = applicationContext,
            title = shown?.title ?: data["title"],
            body = shown?.body ?: data["body"],
            data = data,
            tag = shown?.tag ?: PushRoute.tag(data[PushRoute.NOTIFICATION_ID])
                ?: message.messageId?.let { "m-$it" } ?: "m-${System.currentTimeMillis()}",
            channelId = shown?.channelId,
        )
    }
}
