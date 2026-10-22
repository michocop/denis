package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** A relance scheduled on a recommendation (iOS Models/Reminders.swift). */
@Serializable
data class Reminder(
    val id: String,
    val label: String,
    @Serializable(InstantSerializer::class) val dueAt: Instant,
    val status: Status = Status.Scheduled,
) {
    @Serializable
    enum class Status {
        @SerialName("scheduled") Scheduled,
        @SerialName("sent") Sent,
        @SerialName("done") Done,
        @SerialName("cancelled") Cancelled,
    }

    fun isOverdue(now: Instant = Instant.now()) = status == Status.Scheduled && dueAt < now

    companion object {
        /** The presets of the reminders screen, in seconds from now. */
        val presets = listOf("Demain" to 86_400L, "Dans 3 jours" to 3 * 86_400L, "Dans une semaine" to 7 * 86_400L)

        /** The default due date the screen opens on: in two days. */
        fun defaultDue(now: Instant = Instant.now()): Instant = now.plusSeconds(2 * 86_400L)

        /** An empty label becomes "Relancer <filleul>". */
        fun labelOrDefault(label: String, filleulName: String) = label.trim().ifEmpty { "Relancer $filleulName" }

        /** "22 oct. 2026 14:30", iOS's medium date and short time. */
        fun dueLabel(i: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
            DateTimeFormatter.ofPattern("d MMM yyyy HH:mm", Locale.FRANCE).format(i.atZone(zone))
    }
}
