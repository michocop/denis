package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.DecimalSerializer
import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.time.Instant

/** A row of the admin's member list (`member_overview`). */
@Serializable
data class MemberOverview(
    val id: String,
    val fullName: String = "",
    val email: String = "",
    val phone: String? = null,
    val role: UserRole = UserRole.Apporteur,
    val status: String = "pending",
    val vatLiable: Boolean = false,
    val hasMandate: Boolean = false,
    /** Whether payment details are held in the company's own banking system.
     *  The account number itself is deliberately not stored. */
    val bankDetailsOnFile: Boolean = false,
    val totalRecommendations: Int = 0,
    val activeRecommendations: Int = 0,
    @Serializable(DecimalSerializer::class) val paidTotal: BigDecimal = BigDecimal.ZERO,
    @Serializable(DecimalSerializer::class) val owedTotal: BigDecimal = BigDecimal.ZERO,
    @Serializable(InstantSerializer::class) val lastRecommendationAt: Instant? = null,
    val businessStatus: BusinessStatus? = null,
    /** The last contract this apporteur signed, and whether its PDF is filed. */
    val contractId: String? = null,
    @Serializable(InstantSerializer::class) val contractSignedAt: Instant? = null,
    val contractPdfReady: Boolean? = null,
) {
    val initials: String
        get() = fullName.split(" ").filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1) }.uppercase()
    val isActive: Boolean get() = status == "active"
    val isPending: Boolean get() = status == "pending"
    /** Someone who signed up and never sent anything is worth a call. */
    val hasNeverRecommended: Boolean get() = totalRecommendations == 0
}

/** A signed invoice waiting to be paid (`payable_invoices`). */
@Serializable
data class PayableInvoice(
    val invoiceId: String,
    val number: String = "",
    @Serializable(InstantSerializer::class) val issuedOn: Instant,
    @Serializable(DecimalSerializer::class) val amountTtc: BigDecimal = BigDecimal.ZERO,
    val apporteurId: String = "",
    val apporteurName: String = "",
    /** Paying someone with no bank details on file cannot work. */
    val hasBankDetails: Boolean = false,
    val recommendationId: String = "",
    val filleul: String = "",
)

/** An invitation that has been emailed (what `send-invite` answers). */
@Serializable
data class Invite(val code: String = "", val email: String)

/** A line of the apporteur's own statement (`commission_statement`).
 *  [rewardStatus] is the server's `reward_status`: pending, earned, invoiced,
 *  paid or cancelled. */
@Serializable
data class CommissionLine(
    val recommendationId: String,
    val year: Int,
    val filleul: String = "",
    @Serializable(DecimalSerializer::class) val rewardAmount: BigDecimal? = null,
    val rewardStatus: String = "pending",
    val invoiceNumber: String? = null,
    @Serializable(InstantSerializer::class) val issuedOn: Instant? = null,
    @Serializable(DecimalSerializer::class) val amountTtc: BigDecimal? = null,
    val invoiceStatus: String? = null,
) {
    val isPaid: Boolean get() = rewardStatus == "paid"
}
