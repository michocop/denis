package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.core.SupabaseException
import com.trinityenergie.energycourtage.model.DuplicateCheck
import com.trinityenergie.energycourtage.model.FeedRow
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.RecoDates
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.model.RecommendationCursor
import com.trinityenergie.energycourtage.model.RecommendationDraft
import com.trinityenergie.energycourtage.model.RecommendationStatus
import com.trinityenergie.energycourtage.model.RewardStatus
import com.trinityenergie.energycourtage.model.Stage
import com.trinityenergie.energycourtage.model.StageEvent
import com.trinityenergie.energycourtage.model.UserRole
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID

/** The recommendations: the list, its timeline, creation, and the admin
 *  powers behind the action sheet (iOS RecommendationsRepository). Ids are
 *  the server's UUIDs as strings. */
interface RecommendationsRepository {
    suspend fun loadPipeline(): List<Stage>
    /** One page, newest first. [cursor] is the last row already shown; null
     *  asks for the first page. */
    suspend fun loadPage(archived: Boolean, search: String, cursor: RecommendationCursor?): List<Recommendation>
    suspend fun advanceStage(recommendationId: String, stageKey: String): Recommendation

    suspend fun create(draft: RecommendationDraft): Recommendation
    suspend fun reassign(recommendationId: String, adminId: String)
    /** Admin only, and refused once an invoice exists: the invoice copies it. */
    suspend fun setRewardAmount(recommendationId: String, amount: BigDecimal)
    suspend fun archive(recommendationId: String, won: Boolean)
    suspend fun resetPipeline(recommendationId: String)
    suspend fun softDelete(recommendationId: String)
    suspend fun loadAdmins(): List<Profile>

    /** Every live lead with a meeting fixed, soonest first. */
    suspend fun appointments(): List<Recommendation>
    /** Sets, moves or (with null) removes a meeting. */
    suspend fun setAppointment(recommendationId: String, at: Instant?): Recommendation

    /** Warns before a second apporteur claims a lead someone already holds. */
    suspend fun checkDuplicate(phone: String, email: String): DuplicateCheck
    suspend fun note(recommendationId: String): String
    suspend fun saveNote(recommendationId: String, body: String)
    /** One recommendation, for a notification that names one not on the page. */
    suspend fun recommendation(id: String): Recommendation?
    /** A prospect who asked to be forgotten. Admin only. */
    suspend fun eraseFilleul(recommendationId: String)
    /** Issues the invoice for an earned commission; returns the invoice id.
     *  The amount comes from the recommendation, never from the caller. */
    suspend fun issueInvoice(recommendationId: String): String

    companion object { const val PAGE_SIZE = 20 }
}

fun Dependencies.recommendations(): RecommendationsRepository =
    if (isDemo) DemoRecommendationsRepository else SupabaseRecommendationsRepository(requireClient())

/** Reads through `recommendation_feed` (a card and its timeline in one row)
 *  and writes through the RPCs, so the client never encodes an ordering rule
 *  the database already owns. */
class SupabaseRecommendationsRepository(private val client: SupabaseClient) : RecommendationsRepository {

    override suspend fun loadPipeline(): List<Stage> =
        client.decode(client.select("stages", "order=position.asc"))

    override suspend fun loadPage(archived: Boolean, search: String, cursor: RecommendationCursor?): List<Recommendation> {
        val pipeline = loadPipeline()
        // paging and searching in one RPC: the search index is on the base table
        val body = buildJsonObject {
            put("p_archived", archived)
            put("p_limit", RecommendationsRepository.PAGE_SIZE)
            if (search.isNotEmpty()) put("p_search", search)
            if (cursor != null) {
                put("p_cursor_at", cursor.createdAt.toString())
                put("p_cursor_id", cursor.id)
            }
        }
        val rows: List<FeedRow> = client.decode(client.rpc("recommendation_page", body))
        return rows.map { it.toRecommendation(pipeline) }
    }

    override suspend fun advanceStage(recommendationId: String, stageKey: String): Recommendation {
        // the RPC returns the raw row; re-read the feed for the card's shape
        client.rpcVoid("advance_stage", buildJsonObject {
            put("p_recommendation_id", recommendationId); put("p_stage_key", stageKey)
        })
        return reload(recommendationId)
    }

    /** The details go in the database; the documents' bytes through Storage,
     *  for which erase_filleul hands back the paths. */
    override suspend fun eraseFilleul(recommendationId: String) {
        val paths = client.decodeWith(ListSerializer(String.serializer()),
            client.rpc("erase_filleul", buildJsonObject { put("p_recommendation_id", recommendationId) }))
        for (path in paths) runCatching { client.removeFile("documents", path) }
    }

    override suspend fun recommendation(id: String): Recommendation? = runCatching { reload(id) }.getOrNull()

    private suspend fun reload(id: String): Recommendation {
        val pipeline = loadPipeline()
        val rows: List<FeedRow> = client.decode(client.select("recommendation_feed", "id=eq.$id"))
        val row = rows.firstOrNull() ?: throw SupabaseException.Decoding("recommendation missing")
        return row.toRecommendation(pipeline)
    }

    @Serializable private data class Created(val id: String)

    override suspend fun create(draft: RecommendationDraft): Recommendation {
        val me = client.userId ?: throw SupabaseException.Unauthenticated()
        // current_stage_id is left out: a trigger sets the entry stage
        val values = buildJsonObject {
            put("filleul_first_name", draft.firstName)
            put("filleul_last_name", draft.lastName)
            put("parrain_id", me)
            if (draft.phone.isNotEmpty()) put("filleul_phone", draft.phone)
            if (draft.email.isNotEmpty()) put("filleul_email", draft.email)
            if (draft.company.isNotEmpty()) put("filleul_company", draft.company)
            draft.trimmedComment?.let { put("apporteur_comment", it) }
            draft.appointmentAt?.let { put("appointment_at", it.toString()) }
            // the server records its own clock: what is sent is the "yes"
            if (draft.consentConfirmed) put("consent_confirmed_at", Instant.now().toString())
        }
        val created: List<Created> = client.decode(client.insert("recommendations", values))
        val id = created.firstOrNull()?.id ?: throw SupabaseException.Decoding("insert returned no row")
        return reload(id)
    }

    override suspend fun appointments(): List<Recommendation> {
        val pipeline = loadPipeline()
        val rows: List<FeedRow> = client.decode(client.select("recommendation_feed",
            "appointment_at=not.is.null&status=eq.active&order=appointment_at.asc"))
        return rows.map { it.toRecommendation(pipeline) }
    }

    override suspend fun setAppointment(recommendationId: String, at: Instant?): Recommendation {
        client.update("recommendations", buildJsonObject { put("appointment_at", at?.toString()) }, "id=eq.$recommendationId")
        return reload(recommendationId)
    }

    override suspend fun reassign(recommendationId: String, adminId: String) =
        client.rpcVoid("reassign_recommendation", buildJsonObject {
            put("p_recommendation_id", recommendationId); put("p_admin_id", adminId)
        })

    override suspend fun setRewardAmount(recommendationId: String, amount: BigDecimal) =
        client.rpcVoid("set_reward_amount", JsonObject(mapOf(
            "p_recommendation_id" to JsonPrimitive(recommendationId),
            "p_amount" to JsonPrimitive(BigDecimal(amount.toPlainString())),
        )))

    override suspend fun archive(recommendationId: String, won: Boolean) =
        client.rpcVoid("archive_recommendation", buildJsonObject {
            put("p_recommendation_id", recommendationId); put("p_won", won)
        })

    override suspend fun resetPipeline(recommendationId: String) =
        client.rpcVoid("reset_pipeline", buildJsonObject { put("p_recommendation_id", recommendationId) })

    override suspend fun softDelete(recommendationId: String) =
        client.rpcVoid("soft_delete_recommendation", buildJsonObject { put("p_recommendation_id", recommendationId) })

    override suspend fun loadAdmins(): List<Profile> =
        client.decode(client.select("profiles", "role=in.(admin,manager)&status=eq.active&order=first_name.asc"))

    override suspend fun checkDuplicate(phone: String, email: String): DuplicateCheck =
        client.decode(client.rpc("check_duplicate_filleul", buildJsonObject {
            put("p_phone", phone); put("p_email", email)
        }))

    override suspend fun note(recommendationId: String): String {
        // RLS scopes personal_notes to their author: no reader filter needed
        val rows = client.select("personal_notes", "select=body&recommendation_id=eq.$recommendationId&limit=1").jsonArray
        return rows.firstOrNull()?.jsonObject?.get("body")?.jsonPrimitive?.content ?: ""
    }

    override suspend fun saveNote(recommendationId: String, body: String) {
        val author = client.userId ?: throw SupabaseException.Unauthenticated()
        // one note per reader per recommendation: an upsert
        client.upsert("personal_notes", buildJsonObject {
            put("recommendation_id", recommendationId)
            put("author_id", author)
            put("body", body)
            put("updated_at", Instant.now().toString())
        }, onConflict = "recommendation_id,author_id")
    }

    override suspend fun issueInvoice(recommendationId: String): String {
        val issued = client.rpc("issue_invoice", buildJsonObject { put("p_recommendation_id", recommendationId) })
        val obj = (issued as? kotlinx.serialization.json.JsonArray)?.firstOrNull() ?: issued
        return obj.jsonObject["id"]?.jsonPrimitive?.content ?: throw SupabaseException.Decoding("issue_invoice returned no id")
    }
}

// ----------------------------------------------------------------- demo

/** Sample data, as the iPhone app's SampleData: the finished Thomas Dubois
 *  card and the same card mid-pipeline. */
object DemoSamples {
    private const val banner = "Contrat signé. Retrouvez-le dans les documents de la recommandation."

    val stages = listOf(
        Stage("00000000-0000-0000-0000-000000000001", "a_contacter", "À contacter", 1),
        Stage("00000000-0000-0000-0000-000000000002", "rdv_programme", "RDV programmé", 2),
        Stage("00000000-0000-0000-0000-000000000003", "proposition_envoyee", "Proposition envoyée", 3),
        Stage("00000000-0000-0000-0000-000000000004", "devis_signe", "Devis signé", 4, isRewardTrigger = true, bannerTemplate = banner),
        Stage("00000000-0000-0000-0000-000000000005", "mission_terminee", "Mission terminée", 5, isTerminal = true, bannerTemplate = banner),
    )

    val comments = mapOf(
        "a_contacter" to "Merci pour la mise en relation. Nous avons bien reçu les coordonnées de Thomas Dubois. Prochain point après le 1er échange.",
        "rdv_programme" to "J'ai contacté Thomas Dubois. Le rendez-vous est planifié. Je vous tiens informé(e) de la suite.",
        "proposition_envoyee" to "J'ai transmis à Thomas Dubois la proposition. Retour attendu très prochainement.",
        "devis_signe" to "Thomas Dubois a signé le devis. Votre récompense est validée, nous revenons vers vous pour le règlement.",
        "mission_terminee" to """
            Bonjour Johann,
            Je vous informe que nous allons procéder au paiement de vos honoraires. Vous recevrez votre gain très prochainement.
            N'oubliez pas de procéder à votre déclaration de revenu en fin d'année.
            Si vous êtes un apporteur d'affaire occasionnel, vous devez déclarer les sommes perçues au titre des bénéfices non commerciaux (BNC) via votre déclaration de revenus - CERFA 2042 C -
            Bonne journée.
        """.trimIndent(),
    )

    /** The invoice the demo's finished recommendation carries. */
    const val invoiceId = "dddddddd-dddd-dddd-dddd-dddddddddddd"

    private fun event(stageKey: String, minutesAgo: Long): StageEvent {
        val stage = stages.first { it.key == stageKey }
        return StageEvent(UUID.randomUUID().toString(), stage.id, comments[stageKey], Instant.now().minusSeconds(minutesAgo * 60))
    }

    fun completed() = Recommendation(
        id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        filleulFirstName = "Thomas", filleulLastName = "Dubois",
        filleulPhone = "+33 6 75 75 75 75",
        parrainName = "Johann Lefeuvre",
        createdAt = Instant.now().minusSeconds(8 * 3600),
        currentStageId = stages[4].id,
        events = listOf(event("a_contacter", 480), event("rdv_programme", 360), event("proposition_envoyee", 240),
            event("devis_signe", 120), event("mission_terminee", 30)),
        rewardAmount = BigDecimal(1000),
        rewardStatus = RewardStatus.Invoiced,
        hasContract = true,
        invoiceNumber = "FA-2026-0001",
        invoiceId = invoiceId,
        daysSinceActivity = 0,
        hasNote = true,
    )

    fun inProgress() = Recommendation(
        id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        filleulFirstName = "Thomas", filleulLastName = "Dubois",
        filleulPhone = "+33 6 75 75 75 75",
        parrainName = "Johann Lefeuvre",
        // created 12 days ago, last moved 11 days ago: "Sans activité depuis 11 jours" holds
        createdAt = Instant.now().minusSeconds(12 * 86_400),
        currentStageId = stages[1].id,
        events = listOf(event("a_contacter", 11 * 1440)),
        rewardAmount = BigDecimal(1000),
        rewardStatus = RewardStatus.Pending,
        // deliberately stale, so the staleness banner has something to show
        daysSinceActivity = 11,
        apporteurComment = "Contrat chez Engie jusqu'en mars. Joignable après 18 h, c'est son associé qui signe.",
        appointmentAt = RecoDates.defaultAppointment(Instant.now().plusSeconds(2 * 86_400)),
    )
}

/** The demo's recommendations, kept as they stand after whatever was done
 *  to them, for as long as the app runs. */
object DemoRecommendationsRepository : RecommendationsRepository {
    private const val DELAY = 120L
    private val lock = Any()
    private var items: MutableList<Recommendation>? = null
    private val notes = mutableMapOf<String, String>()

    private fun store(): MutableList<Recommendation> = items ?: mutableListOf(DemoSamples.completed(), DemoSamples.inProgress()).also { items = it }

    private fun update(id: String, change: (Recommendation) -> Recommendation): Recommendation = synchronized(lock) {
        val list = store()
        val i = list.indexOfFirst { it.id == id }
        if (i < 0) throw IllegalStateException("Recommandation introuvable.")
        change(list[i]).also { list[i] = it }
    }

    /** Back to the two samples; for tests. */
    fun reset() = synchronized(lock) { items = null; notes.clear() }

    override suspend fun loadPipeline(): List<Stage> { delay(DELAY); return DemoSamples.stages }

    override suspend fun loadPage(archived: Boolean, search: String, cursor: RecommendationCursor?): List<Recommendation> {
        delay(DELAY)
        if (cursor != null) return emptyList() // the demo holds one page
        return synchronized(lock) {
            store().filter { it.status.isArchived == archived }
                .filter { search.isEmpty() || it.filleulName.contains(search, ignoreCase = true) || it.parrainName.contains(search, ignoreCase = true) }
        }
    }

    override suspend fun recommendation(id: String) = synchronized(lock) { store().firstOrNull { it.id == id } }

    override suspend fun advanceStage(recommendationId: String, stageKey: String): Recommendation {
        delay(DELAY)
        val stage = DemoSamples.stages.firstOrNull { it.key == stageKey } ?: throw IllegalStateException("Étape inconnue.")
        return update(recommendationId) { reco ->
            if (reco.event(stage) != null) reco
            else reco.copy(
                events = reco.events + StageEvent(UUID.randomUUID().toString(), stage.id, DemoSamples.comments[stageKey], Instant.now()),
                currentStageId = stage.id,
                rewardStatus = if (stage.isRewardTrigger && reco.rewardStatus == RewardStatus.Pending) RewardStatus.Earned else reco.rewardStatus,
                daysSinceActivity = 0,
            )
        }
    }

    override suspend fun create(draft: RecommendationDraft): Recommendation {
        delay(DELAY)
        val reco = Recommendation(
            id = UUID.randomUUID().toString(),
            filleulFirstName = draft.firstName.trim(),
            filleulLastName = draft.lastName.trim(),
            filleulPhone = draft.phone,
            parrainName = "Johann Lefeuvre",
            createdAt = Instant.now(),
            currentStageId = DemoSamples.stages[0].id,
            apporteurComment = draft.trimmedComment,
            appointmentAt = draft.appointmentAt,
        )
        synchronized(lock) { store().add(0, reco) }
        return reco
    }

    override suspend fun appointments(): List<Recommendation> {
        delay(DELAY)
        return synchronized(lock) { store().filter { it.appointmentAt != null }.sortedBy { it.appointmentAt } }
    }

    override suspend fun setAppointment(recommendationId: String, at: Instant?): Recommendation {
        delay(DELAY)
        return update(recommendationId) { it.copy(appointmentAt = at) }
    }

    override suspend fun reassign(recommendationId: String, adminId: String) { delay(DELAY) }

    override suspend fun setRewardAmount(recommendationId: String, amount: BigDecimal) {
        delay(DELAY)
        update(recommendationId) {
            if (it.invoiceNumber != null) throw IllegalStateException("Une facture existe déjà : le montant ne peut plus changer.")
            it.copy(rewardAmount = amount)
        }
    }

    override suspend fun archive(recommendationId: String, won: Boolean) {
        delay(DELAY)
        update(recommendationId) {
            val cancelled = !won && it.rewardStatus in setOf(RewardStatus.Pending, RewardStatus.Earned)
            it.copy(status = if (won) RecommendationStatus.ArchivedWon else RecommendationStatus.ArchivedLost,
                rewardStatus = if (cancelled) RewardStatus.Cancelled else it.rewardStatus)
        }
    }

    override suspend fun resetPipeline(recommendationId: String) {
        delay(DELAY)
        update(recommendationId) {
            it.copy(events = emptyList(), currentStageId = DemoSamples.stages[0].id,
                rewardStatus = if (it.rewardStatus == RewardStatus.Earned) RewardStatus.Pending else it.rewardStatus)
        }
    }

    override suspend fun softDelete(recommendationId: String) {
        delay(DELAY)
        synchronized(lock) { store().removeAll { it.id == recommendationId } }
    }

    override suspend fun loadAdmins(): List<Profile> = listOf(
        Profile(id = Demo.them, role = UserRole.Admin, firstName = "Pierre-Louis", lastName = "Tettamanti",
            email = "pl@trinity-energie.test"),
    )

    override suspend fun checkDuplicate(phone: String, email: String): DuplicateCheck {
        delay(DELAY)
        val digits = phone.filter(Char::isDigit).takeLast(9)
        if (digits.length < 9) return DuplicateCheck()
        val mine = synchronized(lock) {
            store().any { it.status == RecommendationStatus.Active && it.filleulPhone?.filter(Char::isDigit)?.takeLast(9) == digits }
        }
        return DuplicateCheck(alreadyYours = mine)
    }

    override suspend fun note(recommendationId: String): String = synchronized(lock) { notes[recommendationId] ?: "" }

    override suspend fun saveNote(recommendationId: String, body: String) {
        delay(DELAY)
        synchronized(lock) { notes[recommendationId] = body }
        update(recommendationId) { it.copy(hasNote = body.isNotBlank()) }
    }

    override suspend fun eraseFilleul(recommendationId: String) {
        delay(DELAY)
        update(recommendationId) {
            it.copy(filleulFirstName = "Personne", filleulLastName = "effacée", filleulPhone = null, apporteurComment = null, appointmentAt = null)
        }
        DemoDocumentsRepository.removeAll(recommendationId)
    }

    override suspend fun issueInvoice(recommendationId: String): String {
        delay(DELAY)
        update(recommendationId) {
            if (!it.canIssueInvoice) throw IllegalStateException("Aucune commission acquise à facturer.")
            it.copy(invoiceNumber = "FA-2026-0002", invoiceId = DemoSamples.invoiceId,
                rewardStatus = RewardStatus.Invoiced, hasContract = true)
        }
        return DemoSamples.invoiceId
    }
}
