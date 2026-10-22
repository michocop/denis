package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.Locale
import kotlin.math.roundToLong

/** A file attached to a recommendation: the filleul's energy bill, or a
 *  quote, contract or invoice the company attached (iOS Models/Documents.swift). */
@Serializable
data class LeadDocument(
    val id: String,
    val recommendationId: String,
    val kind: String = "other",
    val storagePath: String,
    val filename: String,
    val byteSize: Long? = null,
    val mimeType: String? = null,
    val uploadedBy: String = "",
    @Serializable(InstantSerializer::class) val createdAt: Instant,
) {
    val kindLabel get() = when (kind) {
        "energy_bill" -> "Facture d'énergie"
        "quote" -> "Devis"
        "contract" -> "Contrat"
        "invoice" -> "Facture"
        else -> "Document"
    }

    val isPdf get() = mimeType == "application/pdf" || filename.lowercase().endsWith(".pdf")

    val sizeLabel: String? get() = byteSize?.let(::fileSize)

    /** What the phone's viewer is told the file is. */
    val viewerMimeType get() = mimeType ?: if (isPdf) "application/pdf" else "image/jpeg"

    val subtitle get() = listOfNotNull(kindLabel, sizeLabel).joinToString(" · ")
}

/** A size the way iOS's ByteCountFormatter writes it in French: decimal
 *  units, "245 Ko", "1,2 Mo". */
fun fileSize(bytes: Long): String = when {
    bytes < 1_000 -> "$bytes octets"
    bytes < 1_000_000 -> "${(bytes / 1_000.0).roundToLong()} Ko"
    else -> String.format(Locale.FRANCE, "%.1f Mo", bytes / 1_000_000.0)
}

/** A file ready to send: bytes, the name shown, and what it is. */
class DocumentUpload(
    val data: ByteArray,
    val filename: String,
    val mimeType: String,
    val kind: String = "energy_bill",
) {
    val fileExtension get() = when (mimeType) {
        "application/pdf" -> "pdf"
        "image/png" -> "png"
        "image/heic" -> "heic"
        else -> "jpg"
    }

    val isPdf get() = mimeType == "application/pdf"

    companion object {
        /** The server's own limit, checked before anything is sent. */
        const val MAX_BYTES = 10 * 1024 * 1024
        val ACCEPTED = setOf("application/pdf", "image/jpeg", "image/png", "image/heic")
    }
}

class DocumentException(val kind: Kind) : Exception(kind.message) {
    enum class Kind(val message: String) {
        TooLarge("Ce fichier dépasse 10 Mo."),
        Unsupported("Seuls les PDF et les photos sont acceptés."),
    }
}
