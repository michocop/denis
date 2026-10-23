package com.trinityenergie.energycourtage.signing

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.data.SupabaseContractRepository
import com.trinityenergie.energycourtage.data.SupabaseInvoiceRepository
import com.trinityenergie.energycourtage.data.SupabaseLegalRepository
import com.trinityenergie.energycourtage.data.SupabaseSmsRepository
import com.trinityenergie.energycourtage.model.ApporteurContract
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.SmsPurpose
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.math.BigDecimal
import java.time.Instant

abstract class ServerTest {
    lateinit var server: MockWebServer
    lateinit var client: SupabaseClient

    @Before fun start() {
        server = MockWebServer().apply { start() }
        client = SupabaseClient(server.url("/").toString(), "anon-key")
    }

    @After fun stop() = server.shutdown()

    fun answer(body: String, code: Int = 200) =
        server.enqueue(MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body))

    fun RecordedRequest.json(): JsonObject = Json.parseToJsonElement(body.readUtf8()).jsonObject
}

class SmsRepositoryRequestTest : ServerTest() {
    @Test fun status() = runTest {
        answer("""{"sms_required":true,"phone_verified":false,"masked_phone":null}""")
        val status = SupabaseSmsRepository(client).status()
        assertTrue(status.smsRequired)
        assertFalse(status.phoneVerified)
        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/rest/v1/rpc/my_sms_status", r.path)
        assertEquals("anon-key", r.getHeader("apikey"))
    }

    @Test fun requestCodeSendsOnlyWhatIsSet() = runTest {
        answer("""{"required":true,"masked_phone":"+33 6 •• •• •• 78","expires_at":"2026-10-22T10:00:00+00:00"}""")
        val challenge = SupabaseSmsRepository(client).requestCode(SmsPurpose.SignContract, null, null)
        assertTrue(challenge.required)
        assertEquals("+33 6 •• •• •• 78", challenge.maskedPhone)
        assertEquals(Instant.parse("2026-10-22T10:00:00Z"), challenge.expiresAt)
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/request_sms_code", r.path)
        val body = r.json()
        assertEquals(setOf("p_purpose", "p_resend"), body.keys)
        assertEquals("sign_contract", body["p_purpose"]!!.jsonPrimitive.content)
        assertFalse(body["p_resend"]!!.jsonPrimitive.boolean)
    }

    @Test fun requestCodeForAnInvoiceToANewNumber() = runTest {
        answer("""{"required":false,"session":true}""")
        SupabaseSmsRepository(client).requestCode(SmsPurpose.SignInvoice, "inv-1", "+33612345678", resend = true)
        val body = server.takeRequest().json()
        assertEquals(setOf("p_purpose", "p_resend", "p_invoice_id", "p_phone"), body.keys)
        assertEquals("sign_invoice", body["p_purpose"]!!.jsonPrimitive.content)
        assertEquals("inv-1", body["p_invoice_id"]!!.jsonPrimitive.content)
        assertEquals("+33612345678", body["p_phone"]!!.jsonPrimitive.content)
        assertTrue(body["p_resend"]!!.jsonPrimitive.boolean)
        assertTrue(body["p_resend"]!!.jsonPrimitive.isString.not())
    }

    @Test fun confirmSendsTheDigitsOnly() = runTest {
        answer("""{"ok":false,"reason":"wrong","message":"Code incorrect.","attempts_left":3}""")
        val answer = SupabaseSmsRepository(client).confirm(SmsPurpose.VerifyPhone, "12 34 56", null)
        assertEquals(3, answer.attemptsLeft)
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/confirm_sms_code", r.path)
        val body = r.json()
        assertEquals(setOf("p_purpose", "p_code"), body.keys)
        assertEquals("123456", body["p_code"]!!.jsonPrimitive.content)
        assertEquals("verify_phone", body["p_purpose"]!!.jsonPrimitive.content)
    }
}

class LegalRepositoryRequestTest : ServerTest() {
    @Test fun documentsFromTheView() = runTest {
        answer("""[{"key":"cgu","version":"2","title":"CGU","body":"Texte","sha256":"abc","published_at":"2026-09-18T00:00:00+00:00","accepted":false}]""")
        val docs = SupabaseLegalRepository(client).documents()
        assertEquals("cgu", docs.single().key)
        assertFalse(docs.single().accepted)
        val r = server.takeRequest()
        assertEquals("GET", r.method)
        assertEquals("/rest/v1/legal_documents_for_me?order=key.asc", r.path)
    }

    @Test fun acceptSendsKeyAndDigest() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        SupabaseLegalRepository(client).accept("mandat_facturation", "deadbeef")
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/accept_legal_document", r.path)
        val body = r.json()
        assertEquals(setOf("p_key", "p_sha256"), body.keys)
        assertEquals("mandat_facturation", body["p_key"]!!.jsonPrimitive.content)
        assertEquals("deadbeef", body["p_sha256"]!!.jsonPrimitive.content)
    }
}

class ContractRepositoryRequestTest : ServerTest() {
    private val row = """{"id":"5f0c2a1e-0000-0000-0000-000000000000","profile_id":"p1","signed_at":"2026-10-14T09:30:00.123456+00:00",
        "business_status":"independant","contract_version":"2026-10","signer_full_name":"Johann Lefeuvre","company_name":null,
        "otp_verified":true,"otp_phone":"+33 6 •• •• •• 14","pdf_path":PATH,"contract_sha256":"x","email":"j@x.fr"}"""

    @Test fun latestContractOfAProfile() = runTest {
        answer("[${row.replace("PATH", "null")}]")
        val c = SupabaseContractRepository(client).contract("p1")!!
        assertEquals(BusinessStatus.Independant, c.businessStatus)
        assertEquals("CT-5F0C2A1E", c.reference)
        val r = server.takeRequest()
        assertEquals("GET", r.method)
        assertEquals("/rest/v1/apporteur_contracts?profile_id=eq.p1&order=signed_at.desc&limit=1", r.path)
    }

    @Test fun noContractYet() = runTest {
        answer("[]")
        assertNull(SupabaseContractRepository(client).contract("p1"))
    }

    @Test fun signSendsStatusAndBothDigests() = runTest {
        answer(row.replace("PATH", "null"))
        val c = SupabaseContractRepository(client).sign(BusinessStatus.Societe, "c-sha", "m-sha")
        assertEquals("Johann Lefeuvre", c.signerFullName)
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/sign_apporteur_contract", r.path)
        val body = r.json()
        assertEquals(setOf("p_business_status", "p_contract_sha256", "p_mandate_sha256"), body.keys)
        assertEquals("societe", body["p_business_status"]!!.jsonPrimitive.content)
        assertEquals("c-sha", body["p_contract_sha256"]!!.jsonPrimitive.content)
        assertEquals("m-sha", body["p_mandate_sha256"]!!.jsonPrimitive.content)
    }

    @Test fun pdfAsksForTheRowAgainThenDownloads() = runTest {
        answer("[${row.replace("PATH", "\"p1/CT-5F0C2A1E.pdf\"")}]")
        server.enqueue(MockResponse().setBody("%PDF-1.4"))
        val repo = SupabaseContractRepository(client)
        val unfiled = ApporteurContract("5f0c2a1e-0000-0000-0000-000000000000", "p1", Instant.EPOCH, BusinessStatus.Societe, "1", "J")
        val bytes = repo.pdf(unfiled)
        assertArrayEquals("%PDF-1.4".toByteArray(), bytes)
        assertEquals("/rest/v1/apporteur_contracts?id=eq.5f0c2a1e-0000-0000-0000-000000000000&limit=1", server.takeRequest().path)
        val download = server.takeRequest()
        assertEquals("GET", download.method)
        assertEquals("/storage/v1/object/contracts/p1/CT-5F0C2A1E.pdf", download.path)
    }

    @Test fun pdfNotFiledYetIsNull() = runTest {
        answer("[${row.replace("PATH", "null")}]")
        val unfiled = ApporteurContract("5f0c2a1e-0000-0000-0000-000000000000", "p1", Instant.EPOCH, BusinessStatus.Societe, "1", "J")
        assertNull(SupabaseContractRepository(client).pdf(unfiled))
        assertEquals(1, server.requestCount)
    }
}

class InvoiceRepositoryRequestTest : ServerTest() {
    companion object {
        const val DOCUMENT = """{"number":"FA-2026-0007","kind":"invoice","corrects_number":null,"document_sha256":"abc123","pdf_path":null,
          "corrects_invoice_id":null,
          "issuer":{"name":"Pierre-Louis Tettamanti","company":"Trinity Énergie","city":"Aix","siret":null,"address":null,"postal_code":null,"vat_number":null},
          "customer":{"legal_name":"TRINITY ENERGIE","legal_form":"SAS","share_capital":"1 000 €","siren":"102470705","rcs_city":"Lille Métropole",
                      "vat_number":"FR18102470705","address":"945 rue du Général de Gaulle","postal_code":"59310","city":"Aix-en-Pévèle"},
          "apporteur":{"name":"Johann Lefeuvre","company":null,"siret":"12345678900011","legal_form":"Micro-entrepreneur","address":"12 rue",
                       "postal_code":"59000","city":"Lille","vat_number":null},
          "attestation":{"soussigne":"Johann Lefeuvre","mis_en_relation":"TRINITY ENERGIE","avec":"Thomas Dubois",
                         "prestation":"Apport d'affaires - mise en relation","intervenue_le":"17.09.2026"},
          "amount":{"ht":"1500.00","vat_rate":20.00,"vat":"300.00","ttc":"1800.00","currency":"EUR"},
          "legal_mentions":"TVA","payment_method":"Virement bancaire","place":"Aix-en-Pévèle","issued_on":"17.09.2026","due_on":"17.10.2026",
          "self_billing_mention":"Autofacturation","late_payment_mention":"Pénalités","tax_notice":null,"status":"awaiting_signatures",
          "signatures":[{"role":"apporteur","name":"Johann Lefeuvre","signed":true,"signed_at":"2026-09-17T12:00:00.5+00:00","sms_verified":true,"sms_phone":"+33 6 •• •• •• 78"},
                        {"role":"entreprise","name":"Pierre-Louis Tettamanti","signed":false,"signed_at":null}]}"""
    }

    @Test fun documentDecodesTheRpc() = runTest {
        answer(DOCUMENT)
        val doc = SupabaseInvoiceRepository(client).document("inv-7")
        assertEquals("FA-2026-0007", doc.number)
        assertEquals(0, BigDecimal("20").compareTo(doc.amount.vatRate))
        assertEquals("102470705", doc.customer!!.siren)
        assertEquals(true, doc.signatures.first().smsVerified)
        assertFalse(doc.isFullySigned)
        assertTrue(doc.acceptsSignatures)
        assertTrue(doc.isSignedBy("apporteur"))
        assertFalse(doc.isSignedBy("entreprise"))
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/invoice_document", r.path)
        assertEquals("inv-7", r.json()["p_invoice_id"]!!.jsonPrimitive.content)
    }

    @Test fun signSendsTheServersDigest() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        SupabaseInvoiceRepository(client).sign("inv-7", "abc123")
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/sign_invoice", r.path)
        assertEquals("return=minimal", r.getHeader("Prefer"))
        val body = r.json()
        assertEquals(setOf("p_invoice_id", "p_document_sha256"), body.keys)
        assertEquals("abc123", body["p_document_sha256"]!!.jsonPrimitive.content)
    }

    @Test fun creditNoteWithItsReason() = runTest {
        answer("""{"id":"cn-1","number":"FA-2026-0008"}""")
        assertEquals("cn-1", SupabaseInvoiceRepository(client).createCreditNote("inv-7", "Erreur de montant"))
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/create_credit_note", r.path)
        val body = r.json()
        assertEquals(setOf("p_invoice_id", "p_reason"), body.keys)
        assertEquals("Erreur de montant", body["p_reason"]!!.jsonPrimitive.content)
    }

    @Test fun issueFromARecommendation() = runTest {
        answer("""{"id":"inv-9"}""")
        assertEquals("inv-9", SupabaseInvoiceRepository(client).issue("rec-1"))
        val r = server.takeRequest()
        assertEquals("/rest/v1/rpc/issue_invoice", r.path)
        assertEquals("rec-1", r.json()["p_recommendation_id"]!!.jsonPrimitive.content)
    }

    @Test fun latestInvoiceOfARecommendation() = runTest {
        answer("""[{"id":"inv-3"}]""")
        assertEquals("inv-3", SupabaseInvoiceRepository(client).latestInvoiceId("rec-1"))
        assertEquals("/rest/v1/invoices?select=id&recommendation_id=eq.rec-1&order=created_at.desc&limit=1", server.takeRequest().path)
    }

    @Test fun storedPdfIsDownloadedNotRendered() = runTest {
        answer(DOCUMENT)
        server.enqueue(MockResponse().setBody("%PDF-stored"))
        val repo = SupabaseInvoiceRepository(client)
        val doc = repo.document("inv-7").copy(pdfPath = "2026/FA-2026-0007.pdf")
        server.takeRequest()
        val bytes = repo.pdf(doc, "inv-7") { error("must not render a stored invoice") }
        assertArrayEquals("%PDF-stored".toByteArray(), bytes)
        assertEquals("/storage/v1/object/invoices/2026/FA-2026-0007.pdf", server.takeRequest().path)
    }

    @Test fun withoutAStoredPdfItRendersLocally() = runTest {
        answer(DOCUMENT)
        val repo = SupabaseInvoiceRepository(client)
        val doc = repo.document("inv-7")
        val bytes = repo.pdf(doc, "inv-7") { "local:${it.number}".toByteArray() }
        assertEquals("local:FA-2026-0007", bytes.decodeToString())
        assertEquals(1, server.requestCount)
    }

    @Test fun aRefusedSignatureSaysWhy() = runTest {
        answer("""{"message":"Le document a changé depuis son émission."}""", code = 400)
        try {
            SupabaseInvoiceRepository(client).sign("inv-7", "stale")
            throw AssertionError("expected a failure")
        } catch (e: Exception) {
            assertEquals("Le document a changé depuis son émission.", e.message)
        }
    }
}
