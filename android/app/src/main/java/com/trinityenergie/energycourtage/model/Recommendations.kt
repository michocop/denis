package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.DecimalSerializer
import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// ------------------------------------------------------------------ pipeline

/** A pipeline stage, as `public.stages` holds it: labels, banner copy and the
 *  comment template are data, so the back-office can reword the funnel
 *  without a new build (iOS Models/Domain.swift). */
@Serializable
data class Stage(
    val id: String,
    val key: String,
    val label: String,
    val position: Int,
    val isRewardTrigger: Boolean = false,
    val isTerminal: Boolean = false,
    val bannerTemplate: String? = null,
    val commentTemplate: String? = null,
)

/** How one step renders in the timeline: a filled green check, a blue ring
 *  for the step in progress, a faint dot for what is ahead, a red cross for a
 *  lost deal. */
enum class StageState { Completed, Current, Pending, Failed }

/** One reached stage. With no comment the bubble is not drawn at all. */
data class StageEvent(val id: String, val stageId: String, val comment: String?, val completedAt: Instant)

@Serializable
enum class RecommendationStatus {
    @SerialName("active") Active,
    @SerialName("archived_won") ArchivedWon,
    @SerialName("archived_lost") ArchivedLost;

    val isArchived get() = this != Active
}

@Serializable
enum class RewardStatus {
    @SerialName("pending") Pending,
    @SerialName("earned") Earned,
    @SerialName("invoiced") Invoiced,
    @SerialName("paid") Paid,
    @SerialName("cancelled") Cancelled,
}

data class Recommendation(
    val id: String,
    /** The recommended prospect -- the *filleul*. */
    val filleulFirstName: String,
    val filleulLastName: String,
    val filleulPhone: String? = null,
    /** "Recommandé par Johann Lefeuvre". */
    val parrainName: String,
    val createdAt: Instant,
    val currentStageId: String,
    val events: List<StageEvent> = emptyList(),
    val rewardAmount: BigDecimal? = null,
    val rewardStatus: RewardStatus = RewardStatus.Pending,
    val status: RecommendationStatus = RecommendationStatus.Active,
    val hasContract: Boolean = false,
    val invoiceNumber: String? = null,
    val invoiceId: String? = null,
    /** How long this has sat untouched. */
    val daysSinceActivity: Int = 0,
    val hasNote: Boolean = false,
    val pendingReminders: Int = 0,
    /** What the apporteur wrote when filing the lead, for the company to read. */
    val apporteurComment: String? = null,
    /** A meeting already fixed with the filleul, when there is one. */
    val appointmentAt: Instant? = null,
) {
    val filleulName get() = "$filleulFirstName $filleulLastName"

    /** A week of silence is when a lead starts going cold. */
    val isStale get() = status == RecommendationStatus.Active && daysSinceActivity >= 7

    fun event(stage: Stage): StageEvent? = events.firstOrNull { it.stageId == stage.id }

    fun state(stage: Stage): StageState {
        if (status == RecommendationStatus.ArchivedLost && stage.id == currentStageId) return StageState.Failed
        if (event(stage) != null) return StageState.Completed
        return if (stage.id == currentStageId) StageState.Current else StageState.Pending
    }

    /** The green banner: the copy of the highest stage reached. */
    fun bannerText(pipeline: List<Stage>): String? =
        pipeline.filter { event(it) != null }.maxByOrNull { it.position }?.bannerTemplate

    /** The amount surfaces only once the reward has been triggered. */
    val displayedAmount: BigDecimal? get() = if (rewardStatus == RewardStatus.Pending) null else rewardAmount

    // ------------------------------------------------- derived for the card

    fun progress(pipeline: List<Stage>): Double {
        if (pipeline.isEmpty()) return 0.0
        return pipeline.count { state(it) == StageState.Completed }.toDouble() / pipeline.size
    }

    private fun isFailed(pipeline: List<Stage>) = pipeline.any { state(it) == StageState.Failed }

    /** The chip on the card: where the lead stands. */
    fun currentStageLabel(pipeline: List<Stage>): String? {
        if (status.isArchived) return "Archivée"
        if (isFailed(pipeline)) return "Non abouti"
        val ordered = pipeline.sortedBy { it.position }
        if (progress(pipeline) >= 1.0) return "Terminée"
        // the stage being worked on, or -- right after one was validated, when
        // none is open yet -- the last one reached, rather than no label at all
        return ordered.firstOrNull { state(it) == StageState.Current }?.label
            ?: ordered.lastOrNull { state(it) == StageState.Completed }?.label
    }

    enum class Tint { Brand, Success, Destructive }

    fun stageTint(pipeline: List<Stage>): Tint = when {
        isFailed(pipeline) -> Tint.Destructive
        progress(pipeline) >= 1.0 -> Tint.Success
        else -> Tint.Brand
    }

    fun isPipelineComplete(pipeline: List<Stage>): Boolean {
        val last = pipeline.maxByOrNull { it.position } ?: return false
        return event(last) != null
    }

    /** The next stage that has not been reached: what "Valider l'étape" sets. */
    fun nextStage(pipeline: List<Stage>): Stage? = pipeline.sortedBy { it.position }.firstOrNull { event(it) == null }

    /** "Établir la facture": the commission is earned and nothing is issued yet. */
    val canIssueInvoice get() = rewardStatus == RewardStatus.Earned && invoiceNumber == null

    val statusLabel get() = when (status) {
        RecommendationStatus.Active -> "En cours"
        RecommendationStatus.ArchivedWon -> "Gagnée"
        RecommendationStatus.ArchivedLost -> "Perdue"
    }

    val rewardLabel get() = when (rewardStatus) {
        RewardStatus.Pending -> "En attente"
        RewardStatus.Earned -> "Acquise"
        RewardStatus.Invoiced -> "Facturée"
        RewardStatus.Paid -> "Réglée"
        RewardStatus.Cancelled -> "Annulée"
    }

    val initials get() = filleulName.split(" ").filter { it.isNotBlank() }.take(2)
        .joinToString("") { it.first().uppercase() }
}

/** One row of the stepper. */
data class StageRow(val id: String, val label: String, val state: StageState, val showsReward: Boolean, val comment: String?)

fun Recommendation.stepperRows(pipeline: List<Stage>): List<StageRow> =
    pipeline.sortedBy { it.position }.map { stage ->
        StageRow(stage.id, stage.label, state(stage), stage.isRewardTrigger, event(stage)?.comment)
    }

// ------------------------------------------------------------------- wire

/** One row of `recommendation_feed` / `recommendation_page()`: a card and its
 *  whole timeline. Events name their stage by key; [toRecommendation] maps
 *  them onto the pipeline's ids. */
@Serializable
data class FeedRow(
    val id: String,
    val filleulFirstName: String = "",
    val filleulLastName: String = "",
    val filleulPhone: String? = null,
    val parrainName: String = "",
    @Serializable(InstantSerializer::class) val createdAt: Instant,
    val currentStageKey: String = "",
    val rewardStatus: RewardStatus = RewardStatus.Pending,
    val status: RecommendationStatus = RecommendationStatus.Active,
    @Serializable(DecimalSerializer::class) val rewardAmount: BigDecimal? = null,
    val events: List<Event> = emptyList(),
    val hasContract: Boolean = false,
    val invoiceNumber: String? = null,
    val invoiceId: String? = null,
    val daysSinceActivity: Int = 0,
    val hasNote: Boolean = false,
    val pendingReminders: Int = 0,
    val apporteurComment: String? = null,
    @Serializable(InstantSerializer::class) val appointmentAt: Instant? = null,
) {
    @Serializable
    data class Event(
        val stageKey: String,
        val comment: String? = null,
        @Serializable(InstantSerializer::class) val completedAt: Instant,
    )

    fun toRecommendation(pipeline: List<Stage>): Recommendation {
        val byKey = pipeline.associateBy { it.key }
        return Recommendation(
            id = id,
            filleulFirstName = filleulFirstName,
            filleulLastName = filleulLastName,
            filleulPhone = filleulPhone,
            parrainName = parrainName,
            createdAt = createdAt,
            currentStageId = byKey[currentStageKey]?.id ?: "",
            events = events.mapNotNull { e ->
                byKey[e.stageKey]?.let { StageEvent("${id}-${e.stageKey}", it.id, e.comment, e.completedAt) }
            },
            rewardAmount = rewardAmount,
            rewardStatus = rewardStatus,
            status = status,
            hasContract = hasContract,
            invoiceNumber = invoiceNumber,
            invoiceId = invoiceId,
            daysSinceActivity = daysSinceActivity,
            hasNote = hasNote,
            pendingReminders = pendingReminders,
            apporteurComment = apporteurComment,
            appointmentAt = appointmentAt,
        )
    }
}

// --------------------------------------------------------------- creating

/** Says only *that* a lead is held, never by whom. */
@Serializable
data class DuplicateCheck(val alreadyYours: Boolean = false, val heldBySomeoneElse: Boolean = false) {
    val warning: String? get() = when {
        alreadyYours -> RecoStrings.duplicateAlreadyYours
        heldBySomeoneElse -> RecoStrings.duplicateHeldByAnother
        else -> null
    }

    /** Already in your own list is a mistake worth blocking; held by someone
     *  else is the apporteur's call. */
    val blocksSubmission get() = alreadyYours
}

/** What the create form collects. The consent is the lawful basis for
 *  storing the details of someone who never signed up. */
data class RecommendationDraft(
    val firstName: String = "",
    val lastName: String = "",
    val phone: String = "",
    val email: String = "",
    val company: String = "",
    /** For the company: when to call, the current supplier, who decides. */
    val comment: String = "",
    /** Only when a meeting is needed or already fixed. */
    val appointmentAt: Instant? = null,
    val consentConfirmed: Boolean = false,
) {
    val trimmedComment: String? get() = comment.trim().ifEmpty { null }

    val isValid get() = firstName.isNotBlank() && lastName.isNotBlank() && phone.isNotBlank() &&
        consentConfirmed && comment.length <= COMMENT_LIMIT

    /** Worth asking the server about: a full phone number or an address. */
    val worthDuplicateCheck get() = phone.count(Char::isDigit) >= 9 || email.contains("@")

    companion object { const val COMMENT_LIMIT = 2000 }
}

/** Where the last page stopped: a position in the ordering, not a row count,
 *  so rows arriving meanwhile cannot make a page skip or repeat entries. */
data class RecommendationCursor(val createdAt: Instant, val id: String)

enum class RecommendationFilter { Active, Archived; val isArchived get() = this == Archived }

// ------------------------------------------------------------------- copy

object RecoStrings {
    const val duplicateAlreadyYours =
        "Vous avez déjà recommandé cette personne. Retrouvez-la dans vos recommandations actives."
    const val duplicateHeldByAnother =
        "Cette personne est déjà suivie par une autre recommandation en cours. Vous pouvez envoyer la vôtre, mais la récompense reviendra à la première mise en relation."

    fun idleFor(days: Int) = if (days <= 1) "Mise à jour aujourd'hui" else "Sans activité depuis $days jours"
}

/** The card's and the detail's ways of saying when. */
object RecoDates {
    private val fr = Locale.FRANCE

    /** "Aujourd'hui", "Hier", "17/09", or "17/09/25" for another year. */
    fun relativeDay(date: Instant, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String {
        val d = date.atZone(zone).toLocalDate()
        val today = now.atZone(zone).toLocalDate()
        if (d == today) return "Aujourd'hui"
        if (d == today.minusDays(1)) return "Hier"
        val pattern = if (d.year == today.year) "dd/MM" else "dd/MM/yy"
        return DateTimeFormatter.ofPattern(pattern, fr).format(d)
    }

    /** "Aujourd'hui à 14:57", "Hier à 14:57", otherwise "17/09/2026 à 14:57". */
    fun relativeDate(date: Instant, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String {
        val z = date.atZone(zone)
        val time = DateTimeFormatter.ofPattern("HH:mm", fr).format(z)
        val d: LocalDate = z.toLocalDate()
        val today = now.atZone(zone).toLocalDate()
        return when (d) {
            today -> "Aujourd'hui à $time"
            today.minusDays(1) -> "Hier à $time"
            else -> "${DateTimeFormatter.ofPattern("dd/MM/yyyy", fr).format(d)} à $time"
        }
    }

    /** "mardi 10 novembre à 14:30", with the year when it is another one. */
    fun appointment(date: Instant, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String {
        val z = date.atZone(zone)
        val pattern = if (z.year == now.atZone(zone).year) "EEEE d MMMM" else "EEEE d MMMM yyyy"
        return "${DateTimeFormatter.ofPattern(pattern, fr).format(z)} à ${DateTimeFormatter.ofPattern("HH:mm", fr).format(z)}"
    }

    /** Tomorrow at 10:00: where the picker starts. */
    fun defaultAppointment(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): Instant =
        now.atZone(zone).toLocalDate().plusDays(1).atTime(10, 0).atZone(zone).toInstant()
}

/** The meetings as the company reads them: the next one first, then those
 *  gone by, the latest first. */
data class AppointmentAgenda(val upcoming: List<Recommendation>, val past: List<Recommendation>) {
    companion object {
        fun of(meetings: List<Recommendation>, now: Instant = Instant.now()): AppointmentAgenda {
            val (upcoming, past) = meetings.filter { it.appointmentAt != null }.partition { !it.appointmentAt!!.isBefore(now) }
            return AppointmentAgenda(upcoming.sortedBy { it.appointmentAt }, past.sortedByDescending { it.appointmentAt })
        }
    }
}
