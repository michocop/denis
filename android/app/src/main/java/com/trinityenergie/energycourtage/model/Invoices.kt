package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.DecimalSerializer
import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.time.Instant

/** Mirrors `invoice_document()` exactly. One shape for the PDF renderer and
 *  the in-app viewer, so what is signed is what was shown. */
@Serializable
data class InvoiceDocument(
    val number: String,
    /** Computed by the database over the invoice's canonical text. The client
     *  signs this value rather than reproducing the canonicalisation. */
    val documentSha256: String? = null,
    /** Set once a PDF has been produced and kept; the app then downloads that
     *  file instead of rendering a second one. */
    val pdfPath: String? = null,
    /** "invoice" or "credit_note". */
    val kind: String? = null,
    val correctsNumber: String? = null,
    val issuer: Party,
    /** The company, by its legal identity, as it stood when the invoice was
     *  issued. Absent on invoices issued before it was recorded. */
    val customer: Customer? = null,
    val apporteur: Party,
    val attestation: Attestation,
    val amount: Amount,
    val legalMentions: String = "",
    val paymentMethod: String = "",
    val place: String = "",
    val issuedOn: String = "",
    val dueOn: String? = null,
    /** "Autofacturation …": the company drew the invoice up in the apporteur's name. */
    val selfBillingMention: String? = null,
    /** The late-payment rate and the 40 € recovery fee (art. L441-10). */
    val latePaymentMention: String? = null,
    val taxNotice: String? = null,
    val status: String,
    val signatures: List<Signature> = emptyList(),
) {
    @Serializable
    data class Party(
        val name: String,
        val company: String? = null,
        val city: String? = null,
        val siret: String? = null,
        val legalForm: String? = null,
        val address: String? = null,
        val postalCode: String? = null,
        val vatNumber: String? = null,
    )

    @Serializable
    data class Customer(
        val legalName: String,
        val legalForm: String? = null,
        val shareCapital: String? = null,
        val siren: String,
        val rcsCity: String? = null,
        val vatNumber: String? = null,
        val address: String,
        val postalCode: String,
        val city: String,
    )

    @Serializable
    data class Attestation(
        val soussigne: String,
        val misEnRelation: String? = null,
        val avec: String,
        val prestation: String,
        val intervenueLe: String,
    )

    @Serializable
    data class Amount(
        val ht: String,
        @Serializable(DecimalSerializer::class) val vatRate: BigDecimal = BigDecimal.ZERO,
        val vat: String,
        val ttc: String,
        val currency: String = "EUR",
    )

    @Serializable
    data class Signature(
        val role: String,
        val name: String,
        val signed: Boolean,
        @Serializable(InstantSerializer::class) val signedAt: Instant? = null,
        /** Confirmed with a code sent by SMS, to the number masked here. */
        val smsVerified: Boolean? = null,
        val smsPhone: String? = null,
    ) {
        val label get() = if (role == "apporteur") "Signature de l'apporteur" else "Signature de l'entreprise"
    }

    val isFullySigned get() = signatures.all { it.signed }
    val isCreditNote get() = kind == "credit_note"

    /** Still open for signatures. The server refuses one on a void invoice or a sealed one. */
    val acceptsSignatures get() = status == "draft" || status == "awaiting_signatures"

    /** Whether the party signing as [role] ("apporteur" or "entreprise") has. */
    fun isSignedBy(role: String) = signatures.firstOrNull { it.role == role }?.signed ?: false
}

/** "0", "20", "5.5": the rate as the database holds it, without trailing zeros. */
fun BigDecimal.plainRate(): String =
    if (signum() == 0) "0" else stripTrailingZeros().toPlainString()
