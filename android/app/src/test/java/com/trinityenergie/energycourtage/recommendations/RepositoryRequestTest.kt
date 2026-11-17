package com.trinityenergie.energycourtage.recommendations

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.data.DocumentsRepository
import com.trinityenergie.energycourtage.data.SupabaseDocumentsRepository
import com.trinityenergie.energycourtage.data.SupabaseRecommendationsRepository
import com.trinityenergie.energycourtage.data.SupabaseRemindersRepository
import com.trinityenergie.energycourtage.data.pollChanges
import com.trinityenergie.energycourtage.model.DocumentException
import com.trinityenergie.energycourtage.model.DocumentUpload
import com.trinityenergie.energycourtage.model.LeadDocument
import com.trinityenergie.energycourtage.model.RecommendationCursor
import com.trinityenergie.energycourtage.model.RecommendationDraft
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.math.BigDecimal
import java.time.Instant
import java.util.concurrent.CopyOnWriteArrayList

/** What each repository sends: path, method and body keys, as iOS sends them. */
class RepositoryRequestTest {
    private lateinit var server: MockWebServer
    private lateinit var client: SupabaseClient
    private val requests = CopyOnWriteArrayList<Pair<RecordedRequest, String>>()
    /** path prefix -> body answered */
    private val answers = mutableMapOf<String, String>()

    private val stagesJson = """[{"id":"s1","key":"a_contacter","label":"À contacter","position":1},
        {"id":"s2","key":"rdv_programme","label":"RDV programmé","position":2}]"""
    private val feedRow = """{"id":"r1","filleul_first_name":"Thomas","filleul_last_name":"Dubois","parrain_name":"Johann Lefeuvre",
        "created_at":"2026-10-20T10:15:30.123456+00:00","current_stage_key":"rdv_programme","reward_status":"pending",
        "status":"active","events":[{"stage_key":"a_contacter","completed_at":"2026-10-20T11:00:00+00:00"}]}"""

    @Before fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = request.body.readUtf8()
                requests += request to body
                val path = request.path ?: ""
                val answer = answers.entries.firstOrNull { path.startsWith(it.key) }?.value
                return MockResponse().setResponseCode(200).setBody(answer ?: "")
            }
        }
        server.start()
        client = SupabaseClient(server.url("/").toString(), "anon").apply { accessToken = "token"; userId = "me-id" }
        answers["/rest/v1/stages"] = stagesJson
        answers["/rest/v1/recommendation_feed"] = "[$feedRow]"
    }

    @After fun tearDown() = server.shutdown()

    private fun json(body: String): JsonObject = Json.parseToJsonElement(body).jsonObject
    private fun find(pathPrefix: String) = requests.first { (it.first.path ?: "").startsWith(pathPrefix) }

    @Test fun firstPageSendsArchivedAndLimitOnly() = runBlocking {
        answers["/rest/v1/rpc/recommendation_page"] = "[$feedRow]"
        val page = SupabaseRecommendationsRepository(client).loadPage(archived = false, search = "", cursor = null)
        assertEquals(1, page.size)
        assertEquals("s2", page[0].currentStageId)
        val (req, body) = find("/rest/v1/rpc/recommendation_page")
        assertEquals("POST", req.method)
        val b = json(body)
        assertEquals(setOf("p_archived", "p_limit"), b.keys)
        assertEquals(JsonPrimitive(false), b["p_archived"])
        assertEquals(JsonPrimitive(20), b["p_limit"])
        assertEquals("Bearer token", req.getHeader("Authorization"))
    }

    @Test fun nextPageSendsSearchAndTheFullCursor() = runBlocking {
        answers["/rest/v1/rpc/recommendation_page"] = "[]"
        val at = Instant.parse("2026-10-20T10:15:30.123456Z")
        SupabaseRecommendationsRepository(client).loadPage(true, "dubois", RecommendationCursor(at, "r1"))
        val b = json(find("/rest/v1/rpc/recommendation_page").second)
        assertEquals("dubois", b["p_search"]!!.jsonPrimitive.content)
        assertEquals("2026-10-20T10:15:30.123456Z", b["p_cursor_at"]!!.jsonPrimitive.content)
        assertEquals("r1", b["p_cursor_id"]!!.jsonPrimitive.content)
        assertEquals(JsonPrimitive(true), b["p_archived"])
    }

    @Test fun advancingCallsTheRpcThenRereadsTheFeed() = runBlocking {
        val reco = SupabaseRecommendationsRepository(client).advanceStage("r1", "rdv_programme")
        val b = json(find("/rest/v1/rpc/advance_stage").second)
        assertEquals("r1", b["p_recommendation_id"]!!.jsonPrimitive.content)
        assertEquals("rdv_programme", b["p_stage_key"]!!.jsonPrimitive.content)
        assertEquals("/rest/v1/recommendation_feed?id=eq.r1", find("/rest/v1/recommendation_feed").first.path)
        assertEquals("Thomas Dubois", reco.filleulName)
    }

    @Test fun creatingInsertsTheLeadWithTheConsentAndLeavesEmptyFieldsOut() = runBlocking {
        answers["/rest/v1/recommendations"] = """[{"id":"r1"}]"""
        SupabaseRecommendationsRepository(client).create(RecommendationDraft(
            firstName = "Thomas", lastName = "Dubois", phone = "+33 6 75 75 75 75", comment = "  Engie  ", consentConfirmed = true))
        val (req, body) = find("/rest/v1/recommendations")
        assertEquals("POST", req.method)
        assertEquals("return=representation", req.getHeader("Prefer"))
        val b = json(body)
        assertEquals(setOf("filleul_first_name", "filleul_last_name", "parrain_id", "filleul_phone", "apporteur_comment", "consent_confirmed_at"), b.keys)
        assertEquals("me-id", b["parrain_id"]!!.jsonPrimitive.content)
        assertEquals("Engie", b["apporteur_comment"]!!.jsonPrimitive.content)
    }

    @Test fun aMeetingGoesOutOnlyWhenThereIsOne() = runBlocking {
        val at = Instant.parse("2026-11-10T13:30:00Z")
        runCatching { SupabaseRecommendationsRepository(client).create(RecommendationDraft(
            firstName = "Thomas", lastName = "Dubois", phone = "+33 6 75 75 75 75", appointmentAt = at, consentConfirmed = true)) }
        assertEquals("2026-11-10T13:30:00Z", json(find("/rest/v1/recommendations").second)["appointment_at"]!!.jsonPrimitive.content)
    }

    @Test fun removingAMeetingSendsANull() = runBlocking {
        runCatching { SupabaseRecommendationsRepository(client).setAppointment("r1", null) }
        val (req, body) = find("/rest/v1/recommendations")
        assertEquals("PATCH", req.method)
        assertEquals(kotlinx.serialization.json.JsonNull, json(body)["appointment_at"])
    }

    @Test fun theCommissionGoesOutAsANumber() = runBlocking {
        SupabaseRecommendationsRepository(client).setRewardAmount("r1", BigDecimal("1000.50"))
        val b = json(find("/rest/v1/rpc/set_reward_amount").second)
        val amount = b["p_amount"]!!.jsonPrimitive
        assertFalse(amount.isString)
        assertEquals("1000.50", amount.content)
    }

    @Test fun adminPowersCallTheirRpcs() = runBlocking {
        val repo = SupabaseRecommendationsRepository(client)
        repo.reassign("r1", "a1")
        repo.archive("r1", won = false)
        repo.resetPipeline("r1")
        repo.softDelete("r1")
        assertEquals("a1", json(find("/rest/v1/rpc/reassign_recommendation").second)["p_admin_id"]!!.jsonPrimitive.content)
        assertEquals(JsonPrimitive(false), json(find("/rest/v1/rpc/archive_recommendation").second)["p_won"])
        assertEquals(setOf("p_recommendation_id"), json(find("/rest/v1/rpc/reset_pipeline").second).keys)
        assertEquals(setOf("p_recommendation_id"), json(find("/rest/v1/rpc/soft_delete_recommendation").second).keys)
    }

    @Test fun adminsAreTheActiveAdministrators() = runBlocking {
        answers["/rest/v1/profiles"] = """[{"id":"a1","role":"admin","first_name":"Pierre-Louis","last_name":"Tettamanti","email":"pl@x.fr"}]"""
        val admins = SupabaseRecommendationsRepository(client).loadAdmins()
        assertEquals("Pierre-Louis Tettamanti", admins.single().fullName)
        val url = find("/rest/v1/profiles").first.requestUrl!!
        assertEquals("in.(admin,manager)", url.queryParameter("role"))
        assertEquals("eq.active", url.queryParameter("status"))
        assertEquals("first_name.asc", url.queryParameter("order"))
    }

    @Test fun duplicateCheckSendsPhoneAndEmail() = runBlocking {
        answers["/rest/v1/rpc/check_duplicate_filleul"] = """{"already_yours":true,"held_by_someone_else":false}"""
        val check = SupabaseRecommendationsRepository(client).checkDuplicate("0675757575", "")
        assertTrue(check.blocksSubmission)
        assertEquals(setOf("p_phone", "p_email"), json(find("/rest/v1/rpc/check_duplicate_filleul").second).keys)
    }

    @Test fun notesAreReadAndUpsertedPerAuthor() = runBlocking {
        answers["/rest/v1/personal_notes?select"] = """[{"body":"Rappeler jeudi"}]"""
        val repo = SupabaseRecommendationsRepository(client)
        assertEquals("Rappeler jeudi", repo.note("r1"))
        repo.saveNote("r1", "Nouveau")
        val (req, body) = requests.last { (it.first.path ?: "").startsWith("/rest/v1/personal_notes?on_conflict") }
        assertEquals("/rest/v1/personal_notes?on_conflict=recommendation_id,author_id", req.path)
        assertEquals("resolution=merge-duplicates,return=representation", req.getHeader("Prefer"))
        assertEquals(setOf("recommendation_id", "author_id", "body", "updated_at"), json(body).keys)
    }

    @Test fun erasingTheFilleulRemovesTheDocumentsItNames() = runBlocking {
        answers["/rest/v1/rpc/erase_filleul"] = """["r1/a.pdf","r1/b.jpg"]"""
        SupabaseRecommendationsRepository(client).eraseFilleul("r1")
        val deletes = requests.filter { it.first.method == "DELETE" }.map { it.first.path }
        assertEquals(listOf("/storage/v1/object/documents/r1/a.pdf", "/storage/v1/object/documents/r1/b.jpg"), deletes)
    }

    @Test fun issuingAnInvoiceReturnsItsId() = runBlocking {
        answers["/rest/v1/rpc/issue_invoice"] = """{"id":"inv-1","number":"FA-2026-0002"}"""
        assertEquals("inv-1", SupabaseRecommendationsRepository(client).issueInvoice("r1"))
        assertEquals(setOf("p_recommendation_id"), json(find("/rest/v1/rpc/issue_invoice").second).keys)
    }

    @Test fun remindersAreListedScheduledAndCompleted() = runBlocking {
        answers["/rest/v1/reminders"] = """[{"id":"m1","label":"Relancer","due_at":"2026-10-23T08:00:00+00:00","status":"scheduled"}]"""
        answers["/rest/v1/rpc/schedule_reminder"] = """{"id":"m2","label":"Relancer","due_at":"2026-10-24T08:00:00+00:00","status":"scheduled","channel":"push"}"""
        val repo = SupabaseRemindersRepository(client)
        assertEquals("m1", repo.reminders("r1").single().id)
        val url = find("/rest/v1/reminders").first.requestUrl!!
        assertEquals("id,label,due_at,status", url.queryParameter("select"))
        assertEquals("due_at.asc", url.queryParameter("order"))
        val made = repo.schedule("r1", "Relancer", Instant.parse("2026-10-24T08:00:00Z"))
        assertEquals("m2", made.id)
        val b = json(find("/rest/v1/rpc/schedule_reminder").second)
        assertEquals(setOf("p_recommendation_id", "p_label", "p_due_at"), b.keys)
        assertEquals("2026-10-24T08:00:00Z", b["p_due_at"]!!.jsonPrimitive.content)
        repo.complete("m2")
        assertEquals("m2", json(find("/rest/v1/rpc/complete_reminder").second)["p_reminder_id"]!!.jsonPrimitive.content)
    }

    @Test fun uploadingStoresTheFileUnderItsLeadThenRegistersIt() = runBlocking {
        answers["/rest/v1/rpc/register_document"] = """{"id":"d1","recommendation_id":"r1","kind":"energy_bill",
            "storage_path":"r1/x.pdf","filename":"Facture.pdf","byte_size":3,"mime_type":"application/pdf","uploaded_by":"me-id",
            "created_at":"2026-10-22T10:00:00+00:00"}"""
        val doc = SupabaseDocumentsRepository(client).add(DocumentUpload(byteArrayOf(1, 2, 3), "Facture.pdf", "application/pdf"), "R1")
        assertEquals("d1", doc.id)
        val upload = requests.first { (it.first.path ?: "").startsWith("/storage/v1/object/documents/") }.first
        assertEquals("POST", upload.method)
        assertTrue(upload.path!!.matches(Regex("/storage/v1/object/documents/r1/[0-9a-f-]{36}\\.pdf")))
        assertEquals("application/pdf", upload.getHeader("Content-Type"))
        val b = json(find("/rest/v1/rpc/register_document").second)
        assertEquals(setOf("p_recommendation_id", "p_path", "p_filename", "p_byte_size", "p_mime_type", "p_kind"), b.keys)
        assertEquals(upload.path!!.removePrefix("/storage/v1/object/documents/"), b["p_path"]!!.jsonPrimitive.content)
        assertEquals(JsonPrimitive(3), b["p_byte_size"])
        assertEquals("energy_bill", b["p_kind"]!!.jsonPrimitive.content)
    }

    @Test fun aFileOverTenMegabytesIsRefusedBeforeItIsSent() = runBlocking {
        try {
            SupabaseDocumentsRepository(client).add(DocumentUpload(ByteArray(DocumentUpload.MAX_BYTES + 1), "big.pdf", "application/pdf"), "r1")
            fail("expected a refusal")
        } catch (e: DocumentException) {
            assertEquals("Ce fichier dépasse 10 Mo.", e.message)
        }
        try {
            DocumentsRepository.validate(DocumentUpload(ByteArray(3), "a.gif", "image/gif"))
            fail("expected a refusal")
        } catch (e: DocumentException) {
            assertEquals(DocumentException.Kind.Unsupported, e.kind)
        }
        assertTrue(requests.isEmpty())
    }

    @Test fun removingDeletesTheRowThenTheFileTheServerNames() = runBlocking {
        answers["/rest/v1/rpc/remove_document"] = "\"r1/abc.pdf\""
        SupabaseDocumentsRepository(client).remove(LeadDocument("d1", "r1", storagePath = "r1/old.pdf", filename = "a.pdf", createdAt = Instant.EPOCH))
        assertEquals("d1", json(find("/rest/v1/rpc/remove_document").second)["p_document_id"]!!.jsonPrimitive.content)
        assertEquals("/storage/v1/object/documents/r1/abc.pdf", requests.last().first.path)
        assertEquals("DELETE", requests.last().first.method)
    }

    @Test fun documentsAreListedNewestFirst() = runBlocking {
        answers["/rest/v1/documents"] = "[]"
        SupabaseDocumentsRepository(client).documents("r1")
        val url = find("/rest/v1/documents").first.requestUrl!!
        assertEquals("eq.r1", url.queryParameter("recommendation_id"))
        assertEquals("created_at.desc", url.queryParameter("order"))
    }

    @Test fun thePollEmitsOnlyAfterTheBaselineMoves() = runBlocking {
        var n = 0
        val stamps = listOf("2026-10-22T10:00:00+00:00", "2026-10-22T10:00:00+00:00", "2026-10-22T10:05:00+00:00")
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request to ""
                val stamp = stamps[minOf(n++, stamps.lastIndex)]
                return MockResponse().setBody("""[{"updated_at":"$stamp"}]""")
            }
        }
        withTimeout(5_000) { pollChanges(client, intervalMillis = 10).first() }
        // baseline, unchanged, then the change that emits
        assertEquals(3, n)
        val url = requests.first().first.requestUrl!!
        assertEquals("/rest/v1/recommendations", url.encodedPath)
        assertEquals("updated_at", url.queryParameter("select"))
        assertEquals("updated_at.desc", url.queryParameter("order"))
        assertEquals("1", url.queryParameter("limit"))
    }
}
