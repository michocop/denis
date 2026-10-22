package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.Invite
import com.trinityenergie.energycourtage.model.MemberOverview
import com.trinityenergie.energycourtage.model.PayableInvoice
import com.trinityenergie.energycourtage.model.UserRole
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.math.BigDecimal
import java.time.Instant
import java.time.temporal.ChronoUnit

/** iOS AdminRepository (Models/Admin.swift). */
interface AdminRepository {
    suspend fun members(): List<MemberOverview>
    suspend fun setStatus(profileId: String, status: String)
    suspend fun approve(profileId: String)
    /** Creates the invitation and emails it (the send-invite function). */
    suspend fun createInvite(email: String, role: UserRole, autoActivate: Boolean): Invite
    suspend fun payableInvoices(): List<PayableInvoice>
    suspend fun payBatch(invoiceIds: List<String>, reference: String?)
    /** Whether this member's payment details are held in the company's own
     *  banking system. */
    suspend fun setBankDetailsOnFile(profileId: String, onFile: Boolean, reference: String?)
}

fun Dependencies.admin(): AdminRepository = if (isDemo) DemoAdminRepository else SupabaseAdminRepository(requireClient())

/** The role as the server spells it. */
private val UserRole.raw: String
    get() = when (this) { UserRole.Apporteur -> "apporteur"; UserRole.Admin -> "admin"; UserRole.Manager -> "manager" }

class SupabaseAdminRepository(private val client: SupabaseClient) : AdminRepository {
    /** RLS on the underlying tables means an apporteur sees only their own
     *  row, so the same view serves both sides. */
    override suspend fun members(): List<MemberOverview> =
        client.decode(client.select("member_overview", "order=full_name.asc"))

    override suspend fun setStatus(profileId: String, status: String) =
        client.rpcVoid("set_member_status", buildJsonObject { put("p_profile_id", profileId); put("p_status", status) })

    override suspend fun approve(profileId: String) =
        client.rpcVoid("approve_member", buildJsonObject { put("p_profile_id", profileId) })

    /** Through the send-invite function, not create_invite directly: the
     *  function also has Auth email the invitation, which is how an account
     *  comes to exist now that sign-up is closed. Its 400/403/409/502 answers
     *  carry a French `{error}`, which the client turns into the message. */
    override suspend fun createInvite(email: String, role: UserRole, autoActivate: Boolean): Invite =
        client.decode(client.invokeFunction("send-invite", buildJsonObject {
            put("email", email)
            put("role", role.raw)
            put("auto_activate", autoActivate)
        }))

    override suspend fun payableInvoices(): List<PayableInvoice> =
        client.decode(client.select("payable_invoices", "order=apporteur_name.asc,issued_on.asc"))

    override suspend fun payBatch(invoiceIds: List<String>, reference: String?) =
        client.rpcVoid("create_payout_batch", buildJsonObject {
            putJsonArray("p_invoice_ids") { invoiceIds.forEach { add(JsonPrimitive(it)) } }
            if (reference != null) put("p_reference", reference)
        })

    override suspend fun setBankDetailsOnFile(profileId: String, onFile: Boolean, reference: String?) =
        client.rpcVoid("set_bank_details_on_file", buildJsonObject {
            put("p_profile_id", profileId)
            put("p_on_file", onFile)
            if (!reference.isNullOrEmpty()) put("p_reference", reference)
        })
}

/** The demo's members and payables (iOS PreviewAdminRepository), kept for the
 *  session so a validation, a suspension or a payout run stays done. */
object DemoAdminStore {
    const val marie = "22222222-2222-2222-2222-222222222222"
    const val paul = "44444444-4444-4444-4444-444444444444"

    private val mutex = Mutex()
    private var members = mutableListOf<MemberOverview>()
    private var payables = mutableListOf<PayableInvoice>()

    init { reset() }

    fun reset() {
        val now = Instant.now()
        members = mutableListOf(
            MemberOverview(Demo.me, "Johann Lefeuvre", "johann@example.test", "+33 6 11 11 11 11", UserRole.Apporteur,
                "active", vatLiable = false, hasMandate = true, bankDetailsOnFile = true, totalRecommendations = 18,
                activeRecommendations = 4, paidTotal = BigDecimal(2300), owedTotal = BigDecimal(1000),
                lastRecommendationAt = now, businessStatus = BusinessStatus.Societe,
                contractId = "eeeeeeee-0000-0000-0000-000000000001",
                contractSignedAt = now.minus(90, ChronoUnit.DAYS), contractPdfReady = true),
            MemberOverview(marie, "Marie Durand", "marie@example.test", null, UserRole.Apporteur, "pending",
                vatLiable = false, hasMandate = false, bankDetailsOnFile = false),
            MemberOverview(paul, "Paul Riviere", "paul@example.test", null, UserRole.Apporteur, "active",
                vatLiable = true, hasMandate = true, bankDetailsOnFile = false),
        )
        payables = mutableListOf(
            PayableInvoice("ffffffff-0000-0000-0000-000000000004", "FA-2026-0004", now, BigDecimal(300), Demo.me,
                "Johann Lefeuvre", true, "bbbbbbbb-0000-0000-0000-000000000004", "Thomas Dubois"),
            PayableInvoice("ffffffff-0000-0000-0000-000000000005", "FA-2026-0005", now, BigDecimal(750), Demo.me,
                "Johann Lefeuvre", true, "bbbbbbbb-0000-0000-0000-000000000005", "Claire Petit"),
            // deliberately unpayable, so the blocked state is visible
            PayableInvoice("ffffffff-0000-0000-0000-000000000006", "FA-2026-0006", now, BigDecimal(500), paul,
                "Paul Riviere", false, "bbbbbbbb-0000-0000-0000-000000000006", "Luc Martin"),
        )
    }

    fun memberName(id: String): String? = members.firstOrNull { it.id == id }?.fullName

    suspend fun members() = mutex.withLock { members.toList() }
    suspend fun payables() = mutex.withLock { payables.toList() }

    suspend fun update(id: String, change: (MemberOverview) -> MemberOverview) = mutex.withLock {
        val i = members.indexOfFirst { it.id == id }
        if (i >= 0) members[i] = change(members[i])
        if (i >= 0) payables.replaceAll { if (it.apporteurId == id) it.copy(hasBankDetails = members[i].bankDetailsOnFile) else it }
    }

    suspend fun pay(ids: List<String>) = mutex.withLock {
        val paid = payables.filter { it.invoiceId in ids }
        payables.removeAll { it.invoiceId in ids }
        paid.groupBy { it.apporteurId }.forEach { (apporteur, invoices) ->
            val i = members.indexOfFirst { it.id == apporteur }
            if (i >= 0) {
                val total = invoices.fold(BigDecimal.ZERO) { acc, inv -> acc + inv.amountTtc }
                members[i] = members[i].copy(paidTotal = members[i].paidTotal + total,
                    owedTotal = (members[i].owedTotal - total).max(BigDecimal.ZERO))
            }
        }
    }
}

object DemoAdminRepository : AdminRepository {
    override suspend fun members(): List<MemberOverview> { delay(100); return DemoAdminStore.members() }
    override suspend fun setStatus(profileId: String, status: String) = DemoAdminStore.update(profileId) { it.copy(status = status) }
    override suspend fun approve(profileId: String) = DemoAdminStore.update(profileId) { it.copy(status = "active") }
    override suspend fun createInvite(email: String, role: UserRole, autoActivate: Boolean): Invite {
        delay(300); return Invite(code = "K7M2QXPZ", email = email)
    }
    override suspend fun payableInvoices(): List<PayableInvoice> { delay(100); return DemoAdminStore.payables() }
    override suspend fun payBatch(invoiceIds: List<String>, reference: String?) { delay(300); DemoAdminStore.pay(invoiceIds) }
    override suspend fun setBankDetailsOnFile(profileId: String, onFile: Boolean, reference: String?) =
        DemoAdminStore.update(profileId) { it.copy(bankDetailsOnFile = onFile) }
}
