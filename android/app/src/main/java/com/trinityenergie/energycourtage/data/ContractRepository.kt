package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.ApporteurContract
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.raw
import com.trinityenergie.energycourtage.pdf.ContractPdf
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

interface ContractRepository {
    /** The last contract this person signed; null before they sign one. An
     *  apporteur reads their own, an admin anyone's. */
    suspend fun contract(profileId: String): ApporteurContract?

    /** Signs the contract and its annex, the billing mandate, with the code
     *  confirmed just before. The digests are those of the texts shown. */
    suspend fun sign(status: BusinessStatus, contractSha256: String, mandateSha256: String): ApporteurContract

    /** The filed PDF, or null while the server is still preparing it. */
    suspend fun pdf(contract: ApporteurContract): ByteArray?
}

/** The apporteur's contract: signed through sign_apporteur_contract, read from
 *  apporteur_contracts (RLS: the apporteur's own, or any for an admin), and
 *  its PDF from the private "contracts" bucket once the server filed it. */
class SupabaseContractRepository(private val client: SupabaseClient) : ContractRepository {
    private val rows = ListSerializer(ApporteurContract.serializer())

    override suspend fun contract(profileId: String): ApporteurContract? =
        client.decodeWith(rows, client.select("apporteur_contracts",
            "profile_id=eq.$profileId&order=signed_at.desc&limit=1")).firstOrNull()

    override suspend fun sign(status: BusinessStatus, contractSha256: String, mandateSha256: String): ApporteurContract =
        client.decode(client.rpc("sign_apporteur_contract", buildJsonObject {
            put("p_business_status", status.raw)
            put("p_contract_sha256", contractSha256)
            put("p_mandate_sha256", mandateSha256)
        }))

    override suspend fun pdf(contract: ApporteurContract): ByteArray? {
        // filed a moment after the signature: ask again for the row
        val path = contract.pdfPath ?: client.decodeWith(rows,
            client.select("apporteur_contracts", "id=eq.${contract.id}&limit=1")).firstOrNull()?.pdfPath
        return path?.let { client.download(BUCKET, it) }
    }

    companion object { const val BUCKET = "contracts" }
}

/** The demo's one contract, kept for the session so signing it shows on the
 *  profile, as it does for real (iOS PreviewContractRepository). */
object DemoContracts : ContractRepository {
    private val lock = Mutex()
    var signed: ApporteurContract? = null
        private set

    /** For tests, which share this object. */
    suspend fun reset() = lock.withLock { signed = null }

    override suspend fun contract(profileId: String): ApporteurContract? {
        if (profileId == Demo.me) return lock.withLock { signed }
        // the company's view: the demo's apporteurs signed theirs long ago
        return ApporteurContract(
            id = UUID.nameUUIDFromBytes(profileId.toByteArray()).toString(), profileId = profileId,
            signedAt = Instant.now().minus(90, ChronoUnit.DAYS), businessStatus = BusinessStatus.Societe,
            contractVersion = "demo-1", signerFullName = "Johann Lefeuvre", companyName = "Lefeuvre Conseil",
            otpVerified = true, otpPhone = "+33 6 •• •• •• 11", pdfPath = "demo.pdf",
        )
    }

    override suspend fun sign(status: BusinessStatus, contractSha256: String, mandateSha256: String): ApporteurContract {
        delay(500)
        val contract = ApporteurContract(
            id = UUID.randomUUID().toString(), profileId = Demo.me, signedAt = Instant.now(),
            businessStatus = status, contractVersion = "demo-1", signerFullName = "Johann Lefeuvre",
            companyName = if (status == BusinessStatus.Societe) "Lefeuvre Conseil" else null,
            otpVerified = true, otpPhone = "+33 6 •• •• •• 78", pdfPath = "demo.pdf",
        )
        lock.withLock { signed = contract }
        DemoLegal.markAccepted("mandat_facturation")
        DemoLegal.markAccepted("contrat_apporteur")
        return contract
    }

    /** A plain rendering, where there is no server to file the real one: the
     *  texts and the signature certificate, nothing more. */
    override suspend fun pdf(contract: ApporteurContract): ByteArray? =
        ContractPdf.renderDemo(contract, DemoLegal.documents())
}

fun Dependencies.contracts(): ContractRepository = if (isDemo) DemoContracts else SupabaseContractRepository(requireClient())
