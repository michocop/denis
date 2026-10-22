package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.DecimalSerializer
import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.time.Instant

@Serializable
enum class UserRole {
    @SerialName("apporteur") Apporteur,
    @SerialName("admin") Admin,
    @SerialName("manager") Manager;

    val isAdmin get() = this == Admin || this == Manager
}

@Serializable
enum class BusinessStatus { @SerialName("societe") Societe, @SerialName("independant") Independant }

/** What my_account_state() answers: the server decides what the app shows,
 *  so a patched client cannot let a suspended member back in. */
@Serializable
data class AccountState(val state: String, val role: UserRole? = null, val fullName: String? = null)

@Serializable
data class Profile(
    val id: String,
    val role: UserRole = UserRole.Apporteur,
    val firstName: String = "",
    val lastName: String = "",
    val email: String = "",
    val phone: String? = null,
    val companyName: String? = null,
    val siret: String? = null,
    val city: String? = null,
    val legalForm: String? = null,
    val address: String? = null,
    val postalCode: String? = null,
    val vatLiable: Boolean = false,
    val emailNotifications: Boolean? = null,
    @Serializable(InstantSerializer::class) val billingMandateSignedAt: Instant? = null,
    val businessStatus: BusinessStatus? = null,
    @Serializable(InstantSerializer::class) val contractSignedAt: Instant? = null,
) {
    val fullName get() = "$firstName $lastName".trim()
    /** Self-billing needs a prior written mandate. */
    val canBeInvoiced get() = billingMandateSignedAt != null
}

@Serializable
data class DashboardStats(
    val activeCount: Int = 0,
    val archivedCount: Int = 0,
    @Serializable(DecimalSerializer::class) val pendingTotal: BigDecimal = BigDecimal.ZERO,
    @Serializable(DecimalSerializer::class) val earnedTotal: BigDecimal = BigDecimal.ZERO,
    @Serializable(DecimalSerializer::class) val paidTotal: BigDecimal = BigDecimal.ZERO,
    val conversionRate: Double = 0.0,
)
