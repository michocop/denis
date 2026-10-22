package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.CommissionLine
import kotlinx.coroutines.delay
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate

/** iOS CommissionsRepository (Models/Admin.swift). */
interface CommissionsRepository {
    suspend fun statement(year: Int?): List<CommissionLine>
}

fun Dependencies.commissions(): CommissionsRepository =
    if (isDemo) DemoCommissionsRepository else SupabaseCommissionsRepository(requireClient())

class SupabaseCommissionsRepository(private val client: SupabaseClient) : CommissionsRepository {
    override suspend fun statement(year: Int?): List<CommissionLine> {
        val query = "order=issued_on.desc.nullslast" + (year?.let { "&year=eq.$it" } ?: "")
        return client.decode(client.select("commission_statement", query))
    }
}

/** iOS PreviewCommissionsRepository: one paid, one invoiced, one earned. */
object DemoCommissionsRepository : CommissionsRepository {
    override suspend fun statement(year: Int?): List<CommissionLine> {
        delay(100)
        val thisYear = LocalDate.now().year
        val now = Instant.now()
        return listOf(
            CommissionLine("bbbbbbbb-0000-0000-0000-000000000011", thisYear, "Thomas Dubois", BigDecimal(1000), "paid",
                "FA-2026-0001", now, BigDecimal(1000), "paid"),
            CommissionLine("bbbbbbbb-0000-0000-0000-000000000012", thisYear, "Claire Petit", BigDecimal(300), "invoiced",
                "FA-2026-0002", now, BigDecimal(300), "signed"),
            CommissionLine("bbbbbbbb-0000-0000-0000-000000000013", thisYear, "Luc Martin", BigDecimal(750), "earned"),
        ).filter { year == null || it.year == year }
    }
}
