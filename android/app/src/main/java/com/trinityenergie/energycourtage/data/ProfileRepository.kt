package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.DashboardStats
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.UserRole
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import java.math.BigDecimal
import java.time.Instant
import java.time.temporal.ChronoUnit

interface ProfileRepository {
    suspend fun currentProfile(): Profile
    suspend fun save(profile: Profile): Profile
    suspend fun dashboardStats(): DashboardStats
    suspend fun deleteAccount()
    suspend fun exportMyData(): String
}

class SupabaseProfileRepository(private val client: SupabaseClient) : ProfileRepository {
    override suspend fun currentProfile(): Profile = client.decode(client.rpc("my_profile"))

    /** Empty strings go out as null, as on iOS, so clearing a field clears it. */
    override suspend fun save(profile: Profile): Profile {
        fun text(v: String?) = v?.trim()?.takeIf { it.isNotEmpty() }?.let { JsonPrimitive(it) } ?: JsonNull
        val values = JsonObject(mapOf(
            "first_name" to text(profile.firstName),
            "last_name" to text(profile.lastName),
            "phone" to text(profile.phone),
            "company_name" to text(profile.companyName),
            "legal_form" to text(profile.legalForm),
            "siret" to text(profile.siret?.filter(Char::isDigit)),
            "address" to text(profile.address),
            "postal_code" to text(profile.postalCode),
            "city" to text(profile.city),
            "email_notifications" to (profile.emailNotifications?.let { JsonPrimitive(it) } ?: JsonNull),
        ))
        val rows = client.update("profiles", values, "id=eq.${profile.id}").jsonArray
        return rows.firstOrNull()?.let { client.decode<Profile>(it) } ?: profile
    }

    override suspend fun dashboardStats(): DashboardStats = client.decode(client.rpc("dashboard_stats"))
    override suspend fun deleteAccount() = client.rpcVoid("request_account_deletion")
    override suspend fun exportMyData(): String = client.rpc("export_my_data").toString()
}

/** Sample data for the demo: the same figures as the iPhone app's
 *  PreviewProfileRepository. Saved edits are kept for the session. */
class DemoProfileRepository(private val role: UserRole) : ProfileRepository {
    private var saved: Profile? = null

    /** What the demo has signed shows on the profile, as the server's
     *  acceptance sets billing_mandate_signed_at and contract_signed_at: the
     *  mandate, read from its sheet or annexed to the contract, and the
     *  contract from the onboarding. */
    override suspend fun currentProfile(): Profile {
        val base = baseProfile()
        if (role.isAdmin) return base
        val contract = DemoContracts.contract(Demo.me)
        val mandate = DemoLegal.isAccepted("mandat_facturation")
        return base.copy(
            billingMandateSignedAt = base.billingMandateSignedAt ?: if (mandate) (contract?.signedAt ?: Instant.now()) else null,
            contractSignedAt = contract?.signedAt ?: base.contractSignedAt,
            businessStatus = contract?.businessStatus ?: base.businessStatus,
        )
    }

    private fun baseProfile(): Profile = saved ?: Profile(
        id = if (role.isAdmin) Demo.them else Demo.me,
        role = role,
        firstName = if (role.isAdmin) "Pierre-Louis" else "Johann",
        lastName = if (role.isAdmin) "Tettamanti" else "Lefeuvre",
        email = if (role.isAdmin) "pl@trinity-energie.test" else "johann@example.test",
        companyName = if (role.isAdmin) "Trinity Énergie" else "Lefeuvre Conseil",
        city = "Lille",
        billingMandateSignedAt = if (role.isAdmin) Instant.now().minus(90, ChronoUnit.DAYS) else null,
        contractSignedAt = if (role.isAdmin) Instant.now().minus(90, ChronoUnit.DAYS) else null,
    )

    override suspend fun save(profile: Profile): Profile { saved = profile; return profile }

    override suspend fun dashboardStats(): DashboardStats {
        delay(100)
        return DashboardStats(3, 1, BigDecimal(1500), BigDecimal(1300), BigDecimal(300), 25.0)
    }

    override suspend fun deleteAccount() {}
    override suspend fun exportMyData() = "{\"demo\": true}"
}

/** Stable ids for the demo's two people, so chat bubbles land on the right side. */
object Demo {
    const val me = "11111111-1111-1111-1111-111111111111"
    const val them = "33333333-3333-3333-3333-333333333333"
}
