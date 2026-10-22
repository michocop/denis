package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.core.SupabaseException
import com.trinityenergie.energycourtage.model.ThreadKind
import com.trinityenergie.energycourtage.model.UserRole
import com.trinityenergie.energycourtage.ui.profile.SupabaseProfileExtras
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.math.BigDecimal

class ChatAdminRequestsTest {
    private lateinit var server: MockWebServer
    private lateinit var client: SupabaseClient

    @Before fun setUp() {
        server = MockWebServer().apply { start() }
        client = SupabaseClient(server.url("/").toString(), "anon").apply {
            accessToken = "token"; userId = "11111111-1111-1111-1111-111111111111"
        }
    }

    @After fun tearDown() { server.shutdown() }

    private fun answer(body: String, code: Int = 200) = server.enqueue(MockResponse().setResponseCode(code).setBody(body))
    private fun body(r: RecordedRequest): JsonObject = Json.parseToJsonElement(r.body.readUtf8()).jsonObject

    // ---------------------------------------------------------------- chat

    @Test fun threadsReadTheOverviewView() = runTest {
        answer("""[{"id":"t1","kind":"ticket","title":"Problème","counterpart_name":"Support","last_message":"x",
            "last_message_at":"2026-10-20T10:00:00.123456+00:00","unread_count":2,"pinned":true,"archived":false}]""")
        val threads = SupabaseChatRepository(client).loadThreads()
        val r = server.takeRequest()
        assertEquals("GET", r.method)
        assertEquals("/rest/v1/thread_overview?order=last_message_at.desc.nullslast", r.path)
        assertEquals(ThreadKind.Ticket, threads.single().kind)
        assertEquals("Problème", threads.single().displayName)
        assertEquals(2, threads.single().unreadCount)
    }

    @Test fun messagesAreOrderedOldestFirst() = runTest {
        answer("""[{"id":"m1","thread_id":"t1","sender_id":"s","sender_name":"Pierre","body":"Bonjour","created_at":"2026-10-20T10:00:00Z"}]""")
        val messages = SupabaseChatRepository(client).loadMessages("t1")
        assertEquals("/rest/v1/message_feed?thread_id=eq.t1&order=created_at.asc,id.asc", server.takeRequest().path)
        assertEquals("Bonjour", messages.single().body)
    }

    @Test fun sendInsertsWithMeAsSender() = runTest {
        answer("""[{"id":"m2","thread_id":"t1","sender_id":"11111111-1111-1111-1111-111111111111","body":"Salut","created_at":"2026-10-20T10:00:00Z"}]""")
        val saved = SupabaseChatRepository(client).send("Salut", "t1")
        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/rest/v1/messages", r.path)
        assertEquals("return=representation", r.getHeader("Prefer"))
        val b = body(r)
        assertEquals(setOf("thread_id", "sender_id", "body"), b.keys)
        assertEquals("11111111-1111-1111-1111-111111111111", b["sender_id"]!!.jsonPrimitive.content)
        assertEquals("m2", saved.id)
    }

    @Test fun flagsSendOnlyWhatChanges() = runTest {
        answer("")
        SupabaseChatRepository(client).setFlags("t1", pinned = true, archived = null)
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/set_thread_flags", r.path)
        val b = body(r)
        assertEquals(setOf("p_thread_id", "p_pinned"), b.keys)
        assertTrue(b["p_pinned"]!!.jsonPrimitive.boolean)
    }

    @Test fun ticketsAndDirectThreadsAnswerAnId() = runTest {
        answer("\"new-ticket\"")
        answer("\"direct\"")
        answer("\"support\"")
        answer("")
        val repo = SupabaseChatRepository(client)
        assertEquals("new-ticket", repo.openTicket("Sujet", "Texte"))
        assertEquals("direct", repo.startDirectThread("p2"))
        assertEquals("support", repo.startSupportThread())
        repo.markRead("t1")
        server.takeRequest().let { assertEquals("/rest/v1/rpc/open_ticket", it.path); assertEquals(setOf("p_subject", "p_body"), body(it).keys) }
        server.takeRequest().let { assertEquals("/rest/v1/rpc/start_direct_thread", it.path); assertEquals("p2", body(it)["p_other_profile_id"]!!.jsonPrimitive.content) }
        assertEquals("/rest/v1/rpc/start_support_thread", server.takeRequest().path)
        server.takeRequest().let { assertEquals("/rest/v1/rpc/mark_thread_read", it.path); assertEquals(setOf("p_thread_id"), body(it).keys) }
    }

    // ------------------------------------------------------- notifications

    @Test fun notificationsFeedAndDeviceToken() = runTest {
        answer("""[{"id":"n1","kind":"invoice_ready","title":"Facture","body":"","invoice_id":"i1","recommendation_id":"r1","created_at":"2026-10-20T10:00:00Z"}]""")
        answer("3")
        answer("")
        answer("")
        val repo = SupabaseNotificationsRepository(client)
        val items = repo.notifications()
        assertEquals(3, repo.unreadCount())
        repo.register("fcm-token", "android")
        repo.forgetDevices()
        assertEquals("/rest/v1/notification_feed?order=created_at.desc&limit=50", server.takeRequest().path)
        assertEquals("/rest/v1/rpc/unread_notification_count", server.takeRequest().path)
        server.takeRequest().let {
            assertEquals("/rest/v1/rpc/register_device_token", it.path)
            val b = body(it)
            assertEquals(setOf("p_token", "p_platform"), b.keys)
            assertEquals("android", b["p_platform"]!!.jsonPrimitive.content)
        }
        assertEquals("/rest/v1/rpc/forget_my_device_tokens", server.takeRequest().path)
        // the invoice wins over the recommendation it also names
        assertEquals(com.trinityenergie.energycourtage.model.Route.Invoice("i1"), items.single().route)
        assertTrue(items.single().isUnread)
    }

    // --------------------------------------------------------------- admin

    @Test fun inviteGoesThroughTheFunction() = runTest {
        answer("""{"email":"nina@example.test","code":"ABCD2345"}""")
        val invite = SupabaseAdminRepository(client).createInvite("nina@example.test", UserRole.Admin, autoActivate = false)
        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/functions/v1/send-invite", r.path)
        val b = body(r)
        assertEquals(setOf("email", "role", "auto_activate"), b.keys)
        assertEquals("admin", b["role"]!!.jsonPrimitive.content)
        assertFalse(b["auto_activate"]!!.jsonPrimitive.boolean)
        assertEquals("ABCD2345", invite.code)
    }

    @Test fun inviteErrorsSayWhatTheFunctionSaid() = runTest {
        for (status in listOf(409, 403, 502)) {
            answer("""{"error":"Un compte existe déjà pour cette adresse."}""", status)
            try {
                SupabaseAdminRepository(client).createInvite("a@b.fr", UserRole.Apporteur, true)
                fail("expected an error")
            } catch (e: SupabaseException.Http) {
                assertEquals("Un compte existe déjà pour cette adresse.", e.message)
            }
        }
    }

    @Test fun payoutBatchAndBankDetails() = runTest {
        answer(""); answer(""); answer("")
        val repo = SupabaseAdminRepository(client)
        repo.payBatch(listOf("i1", "i2"), null)
        repo.payBatch(listOf("i3"), "VIR-42")
        repo.setBankDetailsOnFile("p1", true, null)
        server.takeRequest().let {
            assertEquals("/rest/v1/rpc/create_payout_batch", it.path)
            val b = body(it)
            assertEquals(setOf("p_invoice_ids"), b.keys)
            assertEquals(listOf("i1", "i2"), b["p_invoice_ids"]!!.jsonArray.map { e -> e.jsonPrimitive.content })
        }
        assertEquals("VIR-42", body(server.takeRequest())["p_reference"]!!.jsonPrimitive.content)
        server.takeRequest().let {
            assertEquals("/rest/v1/rpc/set_bank_details_on_file", it.path)
            assertEquals(setOf("p_profile_id", "p_on_file"), body(it).keys)
        }
    }

    @Test fun membersAndPayablesDecode() = runTest {
        answer("""[{"id":"p1","full_name":"Johann Lefeuvre","email":"j@x.fr","role":"apporteur","status":"pending",
            "vat_liable":false,"has_mandate":true,"bank_details_on_file":false,"total_recommendations":0,"active_recommendations":0,
            "paid_total":0,"owed_total":"1000.50","last_recommendation_at":null,"business_status":"societe",
            "contract_signed_at":"2026-07-01T09:00:00+00:00","contract_pdf_ready":true}]""")
        answer("""[{"invoice_id":"i1","number":"FA-2026-0004","issued_on":"2026-10-01","amount_ttc":300,"apporteur_id":"p1",
            "apporteur_name":"Johann Lefeuvre","has_bank_details":true,"recommendation_id":"r1","filleul":"Thomas Dubois"}]""")
        answer(""); answer("")
        val repo = SupabaseAdminRepository(client)
        val m = repo.members().single()
        val inv = repo.payableInvoices().single()
        repo.approve("p1"); repo.setStatus("p1", "suspended")
        assertEquals("/rest/v1/member_overview?order=full_name.asc", server.takeRequest().path)
        assertEquals("/rest/v1/payable_invoices?order=apporteur_name.asc,issued_on.asc", server.takeRequest().path)
        assertEquals("/rest/v1/rpc/approve_member", server.takeRequest().path)
        server.takeRequest().let {
            assertEquals("/rest/v1/rpc/set_member_status", it.path)
            assertEquals("suspended", body(it)["p_status"]!!.jsonPrimitive.content)
        }
        assertTrue(m.isPending)
        assertEquals(0, BigDecimal("1000.50").compareTo(m.owedTotal))
        assertEquals("JL", m.initials)
        assertEquals("FA-2026-0004", inv.number)
    }

    // --------------------------------------------------- commissions, profile

    @Test fun statementFiltersByYearWhenAsked() = runTest {
        answer("""[{"recommendation_id":"r1","year":2026,"filleul":"Thomas Dubois","reward_amount":1000,"reward_status":"paid","issued_on":"2026-03-01"}]""")
        answer("[]")
        val repo = SupabaseCommissionsRepository(client)
        val lines = repo.statement(null)
        repo.statement(2025)
        assertEquals("/rest/v1/commission_statement?order=issued_on.desc.nullslast", server.takeRequest().path)
        assertEquals("/rest/v1/commission_statement?order=issued_on.desc.nullslast&year=eq.2025", server.takeRequest().path)
        assertTrue(lines.single().isPaid)
    }

    @Test fun smsStatusAndContract() = runTest {
        answer("""{"sms_required":true,"phone_verified":true,"masked_phone":"+33 6 •• •• •• 78"}""")
        answer("""[{"id":"5f0c2a1e-1234-4abc-9def-000000000000","signed_at":"2026-07-01T09:00:00+00:00","business_status":"independant"}]""")
        answer("[]")
        val extras = SupabaseProfileExtras(client)
        val status = extras.smsStatus()
        val profile = com.trinityenergie.energycourtage.model.Profile(id = "p1")
        val contract = extras.contract(profile)
        assertNull(extras.contract(profile))
        assertEquals("/rest/v1/rpc/my_sms_status", server.takeRequest().path)
        assertEquals("/rest/v1/apporteur_contracts?select=id,signed_at,business_status&profile_id=eq.p1&order=signed_at.desc&limit=1",
            server.takeRequest().path)
        assertTrue(status.smsRequired && status.phoneVerified)
        assertEquals("CT-5F0C2A1E", contract!!.reference)
    }
}
