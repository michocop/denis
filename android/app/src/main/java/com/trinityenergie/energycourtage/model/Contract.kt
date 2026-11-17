package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.time.Instant

// How an apporteur works -- through a company or a registered business, or as
// a particulier with no SIRET -- decides what the contract and every invoice
// say about them. The enum itself lives with the profile (model/Profile.kt);
// what the onboarding shows of it is here.

val BusinessStatus.raw: String
    get() = when (this) { BusinessStatus.Societe -> "societe"; BusinessStatus.Independant -> "independant" }

val BusinessStatus.label: String
    get() = when (this) { BusinessStatus.Societe -> "Société ou entreprise"; BusinessStatus.Independant -> "Indépendant" }

val BusinessStatus.explanation: String
    get() = when (this) {
        BusinessStatus.Societe -> "SAS, SARL, micro-entrepreneur… Vos commissions sont facturées sous votre SIRET."
        BusinessStatus.Independant -> "Particulier, sans SIRET : jusqu'à ${Particulier.CAP_LABEL} de commissions par an."
    }

/** The forms offered to choose from; the first is preselected. A particulier
 *  has none to choose: theirs is "Particulier". */
val BusinessStatus.legalForms: List<String>
    get() = when (this) {
        BusinessStatus.Societe -> listOf("SASU", "SAS", "EURL", "SARL", "Micro-entrepreneur", "Entreprise individuelle", "SA", "SNC")
        BusinessStatus.Independant -> emptyList()
    }

/** The particulier: an apporteur without a SIRET, whose commissions the
 *  contract limits to 2 400 € per calendar year (the server refuses an
 *  invoice past it, see supabase/migrations/20261027000001_particulier.sql). */
object Particulier {
    const val LEGAL_FORM = "Particulier"
    const val CAP_LABEL = "2 400 €"
    /** A micro-entrepreneur or sole trader trades under their own name. */
    val soleTraderForms = setOf("Micro-entrepreneur", "Entreprise individuelle")
    const val NOTICE = "Sachez qu'au-delà de $CAP_LABEL de commissions par année civile, vous devez exercer " +
        "en société ou en micro-entreprise et renseigner votre SIRET. Cette règle figure dans votre contrat."
}

/** Where a particulier stands for the year (rpc commission_cap). */
@Serializable
data class CommissionCap(
    val particulier: Boolean = false,
    val year: Int = 0,
    val total: Double = 0.0,
    val cap: Double = 2400.0,
    @kotlinx.serialization.SerialName("alert_from") val alertFrom: Double = 1800.0,
) {
    enum class Alert { Approaching, Reached }

    /** Nothing to say until the alert threshold; reached at the ceiling. */
    val alert: Alert?
        get() = when {
            !particulier || total < alertFrom -> null
            total >= cap -> Alert.Reached
            else -> Alert.Approaching
        }
}

/** A contract as it was signed: the server keeps who signed, under which
 *  status, from which verified mobile, and files the PDF. */
@Serializable
data class ApporteurContract(
    val id: String,
    val profileId: String,
    @Serializable(InstantSerializer::class) val signedAt: Instant,
    val businessStatus: BusinessStatus,
    val contractVersion: String,
    val signerFullName: String,
    val companyName: String? = null,
    val otpVerified: Boolean = false,
    val otpPhone: String? = null,
    val pdfPath: String? = null,
) {
    /** What is printed on the PDF and read out on the phone: CT-5F0C2A1E. */
    val reference get() = "CT-" + id.take(8).uppercase()

    /** The file name the share sheet and Files show. */
    val fileName get() = "Contrat apporteur $reference.pdf"
}
