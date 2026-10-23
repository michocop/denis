package com.trinityenergie.energycourtage.ui.profile

import com.trinityenergie.energycourtage.core.InstantSerializer
import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.Profile
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import java.time.Instant

/** What `my_sms_status()` answers (iOS SmsStatus). */
@Serializable
data class SmsStatus(val smsRequired: Boolean = false, val phoneVerified: Boolean = false, val maskedPhone: String? = null)

/** The few fields of the last signed contract the profile card shows. */
@Serializable
data class ContractSummary(
    val id: String,
    @Serializable(InstantSerializer::class) val signedAt: Instant,
    val businessStatus: BusinessStatus,
) {
    /** What is printed on the PDF: CT-5F0C2A1E. */
    val reference: String get() = "CT-" + id.take(8).uppercase()
}

/** The two small reads the Profil screen needs beyond the profile: the SMS
 *  status for the mobile card, and the signed contract for its card. */
interface ProfileExtras {
    suspend fun smsStatus(): SmsStatus
    suspend fun contract(profile: Profile): ContractSummary?
}

internal fun Dependencies.profileExtras(): ProfileExtras =
    if (isDemo) DemoProfileExtras else SupabaseProfileExtras(requireClient())

internal class SupabaseProfileExtras(private val client: SupabaseClient) : ProfileExtras {
    override suspend fun smsStatus(): SmsStatus {
        val answer = client.rpc("my_sms_status")
        return if (answer is JsonNull) SmsStatus() else client.decode(answer)
    }

    /** `apporteur_contracts` (RLS: the apporteur's own), the latest one. */
    override suspend fun contract(profile: Profile): ContractSummary? =
        client.decode<List<ContractSummary>>(client.select("apporteur_contracts",
            "select=id,signed_at,business_status&profile_id=eq.${profile.id}&order=signed_at.desc&limit=1")).firstOrNull()
}

/**
 * The demo, where SMS is required (as on the iPhone demo) and the mobile is
 * not verified until someone says so: the demo phone verification can call
 * [markPhoneVerified] so the card follows. The contract is the one the demo
 * profile says was signed.
 */
object DemoProfileExtras : ProfileExtras {
    @Volatile private var maskedPhone: String? = null

    fun markPhoneVerified(masked: String) { maskedPhone = masked }

    // the demo's SMS store is the one the code screens verify against: a
    // number proven there (onboarding, an invoice) is verified here too
    override suspend fun smsStatus(): SmsStatus {
        val sms = com.trinityenergie.energycourtage.data.DemoSms.status()
        return if (sms.phoneVerified) SmsStatus(smsRequired = sms.smsRequired, phoneVerified = true, maskedPhone = sms.maskedPhone)
               else SmsStatus(smsRequired = sms.smsRequired, phoneVerified = maskedPhone != null, maskedPhone = maskedPhone)
    }

    override suspend fun contract(profile: Profile): ContractSummary? = profile.contractSignedAt?.let {
        ContractSummary("5f0c2a1e-0000-0000-0000-000000000000", it, profile.businessStatus ?: BusinessStatus.Societe)
    }
}
