package com.trinityenergie.energycourtage.ui.money

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.EuroSymbol
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import com.trinityenergie.energycourtage.core.Money
import com.trinityenergie.energycourtage.data.CommissionsRepository
import com.trinityenergie.energycourtage.model.CommissionLine
import com.trinityenergie.energycourtage.ui.components.EmptyState
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.components.SegmentedPicker
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate

/** The statement's arithmetic and its text export (iOS CommissionsViewModel). */
object CommissionRules {
    fun years(lines: List<CommissionLine>): List<Int> = lines.map { it.year }.distinct().sortedDescending()
    fun forYear(lines: List<CommissionLine>, year: Int) = lines.filter { it.year == year }
    fun earned(lines: List<CommissionLine>): BigDecimal = lines.fold(BigDecimal.ZERO) { acc, l -> acc + (l.rewardAmount ?: BigDecimal.ZERO) }
    fun paid(lines: List<CommissionLine>): BigDecimal = earned(lines.filter { it.isPaid })
    fun outstanding(lines: List<CommissionLine>): BigDecimal = earned(lines) - paid(lines)

    fun statusLabel(status: String): String = when (status) {
        "pending" -> "En attente"
        "earned" -> "Acquise"
        "invoiced" -> "Facturée"
        "paid" -> "Réglée"
        "cancelled" -> "Annulée"
        else -> status
    }

    /** As Swift prints a Decimal: 1000, 300.5. */
    private fun plain(amount: BigDecimal): String =
        if (amount.signum() == 0) "0" else amount.stripTrailingZeros().toPlainString()

    /** A plain text statement the apporteur can send to their accountant. */
    fun exportText(name: String, year: Int, lines: List<CommissionLine>): String {
        val forYear = forYear(lines, year)
        val out = mutableListOf("Relevé d'apport d'affaires — $name — $year", "")
        forYear.sortedBy { it.issuedOn ?: Instant.MIN }.forEach { line ->
            out += listOf(
                line.invoiceNumber ?: "—",
                line.filleul,
                line.rewardAmount?.let { "${plain(it)} EUR" } ?: "—",
                statusLabel(line.rewardStatus),
            ).joinToString(" | ")
        }
        out += ""
        out += "Total acquis : ${plain(earned(forYear))} EUR"
        out += "Total réglé  : ${plain(paid(forYear))} EUR"
        out += ""
        out += "Sommes à déclarer au titre des bénéfices non commerciaux (BNC), déclaration de revenus CERFA 2042 C."
        return out.joinToString("\n")
    }
}

/**
 * "Mes gains": the apporteur's own money, by year, and the statement they
 * produce for their tax return (Features/Money/CommissionsView.swift).
 */
@Composable
fun CommissionsScreen(repository: CommissionsRepository, apporteurName: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var lines by remember { mutableStateOf<List<CommissionLine>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var year by remember { mutableIntStateOf(LocalDate.now().year) }

    LaunchedEffect(repository) {
        try {
            lines = repository.statement(null)
            // a statement with nothing this year opens on its latest year
            val years = CommissionRules.years(lines)
            if (years.isNotEmpty() && year !in years) year = years.first()
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        loaded = true
    }

    val years = CommissionRules.years(lines)
    val forYear = CommissionRules.forYear(lines, year)

    FullScreenSheet("Mes gains", onDismiss, back = true) {
        if (years.size > 1) SegmentedPicker(year, years.map { it to it.toString() }, { year = it })

        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Tile("Acquis", Money.euros(CommissionRules.earned(forYear)), Palette.successText)
            Tile("Reste dû", Money.euros(CommissionRules.outstanding(forYear)), Palette.textPrimary)
        }

        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }

        when {
            !loaded -> LoadingBlock()
            forYear.isEmpty() && error == null -> EmptyState(Icons.Outlined.EuroSymbol, "Aucun gain pour le moment")
            else -> {
                forYear.forEach { line ->
                    Row(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                            Text(line.filleul, style = Type.body, color = Palette.textPrimary)
                            Text(line.invoiceNumber ?: "Pas encore facturée", style = Type.caption, color = Palette.textSecondary)
                        }
                        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                            Text(line.rewardAmount?.let { Money.euros(it) } ?: "—", style = Type.body.copy(fontWeight = FontWeight.SemiBold),
                                color = Palette.textPrimary)
                            Text(CommissionRules.statusLabel(line.rewardStatus), style = Type.caption,
                                color = if (line.isPaid) Palette.successText else Palette.textSecondary)
                        }
                    }
                }
                if (forYear.isNotEmpty()) {
                    SecondaryActionButton("Exporter le relevé", icon = Icons.Outlined.Share) {
                        Files.shareText(context, CommissionRules.exportText(apporteurName, year, lines), "Exporter le relevé")
                    }
                    Text("Ces sommes sont à déclarer au titre des bénéfices non commerciaux (BNC), via la déclaration de revenus CERFA 2042 C.",
                        style = Type.caption, color = Palette.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun RowScope.Tile(label: String, value: String, tint: Color) {
    Column(Modifier.weight(1f).cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(label, style = Type.caption, color = Palette.textSecondary)
        Text(value, style = Type.statValue, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
