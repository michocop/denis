package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.InstantSerializer
import com.trinityenergie.energycourtage.core.SupabaseClient
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import java.time.Instant
import kotlin.coroutines.cancellation.CancellationException

/**
 * Tells the list the server has moved on: what raises "De nouveaux éléments
 * sont disponibles" (iOS PollingChangeMonitor).
 *
 * One cheap query every 30 s rather than a WebSocket: the events are
 * human-paced, and a poller survives backgrounding, flaky networks and token
 * refresh with no reconnection logic to get wrong. The first reading is the
 * baseline; only a later change emits. In demo mode nothing ever changes.
 */
fun Dependencies.changes(): Flow<Unit> =
    if (isDemo) flow { awaitCancellation() } else pollChanges(requireClient())

@Serializable
private data class Watermark(@Serializable(InstantSerializer::class) val updatedAt: Instant? = null)

fun pollChanges(client: SupabaseClient, intervalMillis: Long = 30_000): Flow<Unit> = flow {
    var seen: Instant? = null
    while (true) {
        delay(intervalMillis)
        // one row, one column, indexed
        val latest = try {
            client.decode<List<Watermark>>(client.select("recommendations", "select=updated_at&order=updated_at.desc&limit=1"))
                .firstOrNull()?.updatedAt
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        } ?: continue
        val previous = seen
        if (previous != null && latest > previous) emit(Unit)
        seen = latest
    }
}

/** Changes made in this app that another screen shows: a recommendation
 *  created from the form, so the list reloads without waiting for the poll. */
object RecommendationEvents {
    private val _created = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
    val created: SharedFlow<Unit> = _created.asSharedFlow()
    fun notifyCreated() { _created.tryEmit(Unit) }
}
