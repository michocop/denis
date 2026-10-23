package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.time.Instant

// How an apporteur works -- through a company, or on their own -- decides what
// the contract and every invoice say about them. The enum itself lives with
// the profile (model/Profile.kt); what the onboarding shows of it is here.

val BusinessStatus.raw: String
    get() = when (this) { BusinessStatus.Societe -> "societe"; BusinessStatus.Independant -> "independant" }

val BusinessStatus.label: String
    get() = when (this) { BusinessStatus.Societe -> "Société"; BusinessStatus.Independant -> "Indépendant" }

val BusinessStatus.explanation: String
    get() = when (this) {
        BusinessStatus.Societe -> "SAS, SASU, SARL, EURL… Vos commissions sont facturées au nom de votre société."
        BusinessStatus.Independant -> "Micro-entrepreneur ou entreprise individuelle, en votre nom propre."
    }

/** The forms offered to choose from; the first is preselected. */
val BusinessStatus.legalForms: List<String>
    get() = when (this) {
        BusinessStatus.Societe -> listOf("SASU", "SAS", "EURL", "SARL", "SA", "SNC")
        BusinessStatus.Independant -> listOf("Micro-entrepreneur", "Entreprise individuelle")
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
