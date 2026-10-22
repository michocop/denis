package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.Reminder
import kotlinx.coroutines.delay
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.UUID

interface RemindersRepository {
    suspend fun reminders(recommendationId: String): List<Reminder>
    suspend fun schedule(recommendationId: String, label: String, dueAt: Instant): Reminder
    suspend fun complete(reminderId: String)
}

fun Dependencies.reminders(): RemindersRepository =
    if (isDemo) DemoRemindersRepository else SupabaseRemindersRepository(requireClient())

class SupabaseRemindersRepository(private val client: SupabaseClient) : RemindersRepository {
    override suspend fun reminders(recommendationId: String): List<Reminder> =
        client.decode(client.select("reminders",
            "select=id,label,due_at,status&recommendation_id=eq.$recommendationId&order=due_at.asc"))

    override suspend fun schedule(recommendationId: String, label: String, dueAt: Instant): Reminder =
        client.decode(client.rpc("schedule_reminder", buildJsonObject {
            put("p_recommendation_id", recommendationId)
            put("p_label", label)
            put("p_due_at", dueAt.toString())
        }))

    override suspend fun complete(reminderId: String) =
        client.rpcVoid("complete_reminder", buildJsonObject { put("p_reminder_id", reminderId) })
}

/** The demo's reminders: each recommendation starts with the iPhone app's two
 *  samples, and what is scheduled or ticked off stays so while the app runs. */
object DemoRemindersRepository : RemindersRepository {
    private val byReco = mutableMapOf<String, MutableList<Reminder>>()

    private fun list(recommendationId: String) = byReco.getOrPut(recommendationId) {
        mutableListOf(
            Reminder(UUID.randomUUID().toString(), "Relancer Thomas Dubois", Instant.now().plusSeconds(86_400), Reminder.Status.Scheduled),
            Reminder(UUID.randomUUID().toString(), "Envoyer la proposition", Instant.now().minusSeconds(86_400), Reminder.Status.Scheduled),
        )
    }

    override suspend fun reminders(recommendationId: String): List<Reminder> {
        delay(100)
        return synchronized(this) { list(recommendationId).sortedBy { it.dueAt } }
    }

    override suspend fun schedule(recommendationId: String, label: String, dueAt: Instant): Reminder {
        delay(100)
        val reminder = Reminder(UUID.randomUUID().toString(), label, dueAt, Reminder.Status.Scheduled)
        synchronized(this) { list(recommendationId).add(reminder) }
        return reminder
    }

    override suspend fun complete(reminderId: String) {
        delay(100)
        synchronized(this) {
            byReco.values.forEach { l ->
                val i = l.indexOfFirst { it.id == reminderId }
                if (i >= 0) l[i] = l[i].copy(status = Reminder.Status.Done)
            }
        }
    }

    fun reset() = synchronized(this) { byReco.clear() }
}
