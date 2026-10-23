package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.InvoiceDocument
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID

interface InvoiceRepository {
    suspend fun document(invoiceId: String): InvoiceDocument
    suspend fun latestInvoiceId(recommendationId: String): String?
    suspend fun sign(invoiceId: String, documentSha256: String)

    /** The PDF that is legally retained: the stored file when the server has
     *  produced it, and until then [renderLocally]'s rendering of the same
     *  signed document, which is never uploaded. */
    suspend fun pdf(document: InvoiceDocument, invoiceId: String, renderLocally: (InvoiceDocument) -> ByteArray): ByteArray

    /** Issues the invoice for an earned commission. The amount comes from the
     *  recommendation, never from the caller. */
    suspend fun issue(recommendationId: String): String

    /** The only lawful correction to a signed invoice: a new document in the
     *  same series carrying the negative amount. */
    suspend fun createCreditNote(invoiceId: String, reason: String): String
}

@Serializable
private data class IdRow(val id: String)

class SupabaseInvoiceRepository(private val client: SupabaseClient) : InvoiceRepository {
    override suspend fun document(invoiceId: String): InvoiceDocument =
        client.decode(client.rpc("invoice_document", buildJsonObject { put("p_invoice_id", invoiceId) }))

    override suspend fun latestInvoiceId(recommendationId: String): String? =
        client.decodeWith(ListSerializer(IdRow.serializer()), client.select("invoices",
            "select=id&recommendation_id=eq.$recommendationId&order=created_at.desc&limit=1")).firstOrNull()?.id

    /** The hash is checked server-side against the issued invoice, so a client
     *  cannot sign anything other than what it was shown. */
    override suspend fun sign(invoiceId: String, documentSha256: String) =
        client.rpcVoid("sign_invoice", buildJsonObject {
            put("p_invoice_id", invoiceId)
            put("p_document_sha256", documentSha256)
        })

    /** The retained document is produced on the server the moment an invoice
     *  is sealed (the invoice-pdf function), so this only ever downloads it.
     *  Until it exists -- a few seconds after the second signature -- the app
     *  shows its own rendering, which is never uploaded. */
    override suspend fun pdf(document: InvoiceDocument, invoiceId: String, renderLocally: (InvoiceDocument) -> ByteArray): ByteArray {
        val path = document.pdfPath ?: return renderLocally(document)
        return client.download(BUCKET, path)
    }

    override suspend fun issue(recommendationId: String): String =
        client.decodeWith(IdRow.serializer(), client.rpc("issue_invoice", buildJsonObject {
            put("p_recommendation_id", recommendationId)
        })).id

    override suspend fun createCreditNote(invoiceId: String, reason: String): String =
        client.decodeWith(IdRow.serializer(), client.rpc("create_credit_note", buildJsonObject {
            put("p_invoice_id", invoiceId)
            put("p_reason", reason)
        })).id

    companion object { const val BUCKET = "invoices" }
}

/** Demo invoicing that remembers a signature, so the two-signature flow and
 *  the PDF that appears at the end of it can actually be tried rather than
 *  only looked at (iOS PreviewInvoiceRepository and DemoInvoiceStore). */
object DemoInvoices : InvoiceRepository {
    const val SAMPLE_DIGEST = "6b3788b6c0f4de8ada808ece4ce874fe03115720fbe79519337ce86ea382d5d8"

    private val lock = Mutex()
    private val signedBy = mutableSetOf("apporteur")

    /** For tests, which share this object. */
    suspend fun reset() = lock.withLock { signedBy.clear(); signedBy += "apporteur" }

    override suspend fun document(invoiceId: String): InvoiceDocument {
        val (apporteurSigned, entrepriseSigned) = lock.withLock { ("apporteur" in signedBy) to ("entreprise" in signedBy) }
        return InvoiceDocument(
            number = "FA-2026-0001",
            // a real digest's shape: a row of "a"s read as a broken document
            documentSha256 = SAMPLE_DIGEST,
            kind = "invoice",
            issuer = InvoiceDocument.Party(name = "Pierre-Louis Tettamanti", company = "Trinity Énergie", city = "Aix-en-Pévèle"),
            customer = InvoiceDocument.Customer(
                legalName = "TRINITY ENERGIE", legalForm = "SAS", shareCapital = "1 000 €", siren = "102470705",
                rcsCity = "Lille Métropole", vatNumber = "FR18102470705", address = "945 rue du Général de Gaulle",
                postalCode = "59310", city = "Aix-en-Pévèle",
            ),
            apporteur = InvoiceDocument.Party(
                name = "Johann Lefeuvre", company = "Lefeuvre Conseil", city = "Lille", siret = "12345678900011",
                legalForm = "Micro-entreprise", address = "12 rue des Lilas", postalCode = "59000",
            ),
            attestation = InvoiceDocument.Attestation(
                soussigne = "Johann Lefeuvre", misEnRelation = "Trinity Énergie", avec = "Thomas Dubois",
                prestation = "Apport d'affaires - mise en relation", intervenueLe = "17.09.2026",
            ),
            amount = InvoiceDocument.Amount(ht = "300.00", vatRate = BigDecimal.ZERO, vat = "0.00", ttc = "300.00", currency = "EUR"),
            legalMentions = "TVA non applicable – Régime d'exonération de TVA (Article 293B du Code général des impôts)",
            paymentMethod = "Virement bancaire",
            place = "Aix-en-Pévèle",
            issuedOn = "17.09.2026",
            dueOn = "17.10.2026",
            selfBillingMention = "Autofacturation — facture établie par le client au nom et pour le compte du fournisseur (art. 289, I-2 du CGI).",
            latePaymentMention = "En cas de retard de paiement, pénalités au taux de trois fois le taux d'intérêt légal, exigibles sans rappel, et indemnité forfaitaire pour frais de recouvrement de 40 € (art. L441-10 du Code de commerce).",
            taxNotice = "N'oubliez pas de procéder à votre déclaration de revenu en fin d'année.",
            status = if (entrepriseSigned && apporteurSigned) "signed" else "awaiting_signatures",
            signatures = listOf(
                InvoiceDocument.Signature("apporteur", "Johann Lefeuvre", apporteurSigned, if (apporteurSigned) Instant.now() else null),
                InvoiceDocument.Signature("entreprise", "Pierre-Louis Tettamanti", entrepriseSigned, if (entrepriseSigned) Instant.now() else null),
            ),
        )
    }

    override suspend fun latestInvoiceId(recommendationId: String): String = UUID.randomUUID().toString()

    /** The demo has no second party to wait for, so whichever signature is
     *  still missing is the one this tap adds. */
    override suspend fun sign(invoiceId: String, documentSha256: String) {
        lock.withLock { signedBy += if ("apporteur" in signedBy) "entreprise" else "apporteur" }
    }

    /** Rendered locally and not kept anywhere: the demo has no storage behind it. */
    override suspend fun pdf(document: InvoiceDocument, invoiceId: String, renderLocally: (InvoiceDocument) -> ByteArray) =
        renderLocally(document)

    override suspend fun issue(recommendationId: String): String = UUID.randomUUID().toString()
    override suspend fun createCreditNote(invoiceId: String, reason: String): String = UUID.randomUUID().toString()
}

fun Dependencies.invoices(): InvoiceRepository = if (isDemo) DemoInvoices else SupabaseInvoiceRepository(requireClient())
