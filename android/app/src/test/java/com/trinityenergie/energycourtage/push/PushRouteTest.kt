package com.trinityenergie.energycourtage.push

import com.trinityenergie.energycourtage.model.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PushRouteTest {
    private val thread = "0b9f6c1e-2d4a-4f7b-9a51-6f0c2e8d7a10"
    private val recommendation = "11111111-2222-4333-8444-555555555555"
    private val invoice = "5d1c0a2e-7b3f-4e29-8c64-2a9f1e0b7d33"

    @Test fun `a message opens its conversation`() {
        assertEquals(Route.Thread(thread), PushRoute.parse(mapOf("kind" to "message_received", "thread_id" to thread)))
    }

    @Test fun `a stage opens its recommendation`() {
        assertEquals(Route.Recommendation(recommendation),
                     PushRoute.parse(mapOf("recommendation_id" to recommendation)))
    }

    @Test fun `the most specific id wins - an invoice also names its recommendation`() {
        assertEquals(Route.Invoice(invoice),
                     PushRoute.parse(mapOf("recommendation_id" to recommendation, "invoice_id" to invoice)))
        assertEquals(Route.Thread(thread),
                     PushRoute.parse(mapOf("recommendation_id" to recommendation, "thread_id" to thread)))
    }

    @Test fun `FCM's own launch extras around the data are ignored`() {
        val launch = mapOf(
            "google.message_id" to "0:1700000000000000%abc",
            "from" to "123456789012",
            "collapse_key" to "com.trinityenergie.energycourtage",
            "kind" to "invoice_ready",
            "notification_id" to "9a7e2f40-1111-4222-8333-444444444444",
            "invoice_id" to invoice,
        )
        assertEquals(Route.Invoice(invoice), PushRoute.parse(launch))
    }

    @Test fun `an ordinary launch leads nowhere`() {
        assertNull(PushRoute.parse(emptyMap()))
        assertNull(PushRoute.parse(mapOf("thread_id" to null, "recommendation_id" to null, "invoice_id" to null)))
        assertNull(PushRoute.parse(mapOf("kind" to "member_approved", "notification_id" to thread)))
    }

    @Test fun `what is not an id is ignored, and the next one is used`() {
        assertNull(PushRoute.parse(mapOf("thread_id" to "")))
        assertNull(PushRoute.parse(mapOf("thread_id" to "null")))
        assertNull(PushRoute.parse(mapOf("invoice_id" to "'; drop table invoices; --")))
        assertEquals(Route.Recommendation(recommendation),
                     PushRoute.parse(mapOf("invoice_id" to "not-a-uuid", "recommendation_id" to recommendation)))
    }

    @Test fun `ids are normalised as the database writes them`() {
        assertEquals(Route.Thread(thread), PushRoute.parse(mapOf("thread_id" to " ${thread.uppercase()} ")))
    }

    @Test fun `the tag matches the one send-push gives FCM`() {
        assertEquals("n-$thread", PushRoute.tag(thread))
        assertNull(PushRoute.tag(null))
        assertNull(PushRoute.tag(" "))
    }

    @Test fun `push is on only with all four Firebase values`() {
        assertTrue(PushConfig("p", "1:2:android:3", "AIza", "2").isComplete)
        assertFalse(PushConfig("", "", "", "").isComplete)
        assertFalse(PushConfig("p", "1:2:android:3", "AIza", " ").isComplete)
        assertFalse(PushConfig("p", "", "AIza", "2").isComplete)
    }

    @Test fun `a build without firebase properties has push off`() {
        // this worktree has no android/firebase.properties: BuildConfig's values are empty
        assertEquals(PushConfig.fromBuild.isComplete,
                     listOf(com.trinityenergie.energycourtage.BuildConfig.FIREBASE_PROJECT_ID,
                            com.trinityenergie.energycourtage.BuildConfig.FIREBASE_APP_ID,
                            com.trinityenergie.energycourtage.BuildConfig.FIREBASE_API_KEY,
                            com.trinityenergie.energycourtage.BuildConfig.FIREBASE_SENDER_ID).all { it.isNotBlank() })
    }
}
