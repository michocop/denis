package com.trinityenergie.energycourtage.ui.admin

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Money
import com.trinityenergie.energycourtage.data.AdminRepository
import com.trinityenergie.energycourtage.model.PayableInvoice
import com.trinityenergie.energycourtage.ui.components.ConfirmDialog
import com.trinityenergie.energycourtage.ui.components.EmptyState
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.ScreenTitle
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch

/**
 * The payables run: everything signed and unpaid, with a total that matches
 * the transfer file (Features/Admin/PayablesView.swift).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PayablesScreen(repository: AdminRepository, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var invoices by remember { mutableStateOf<List<PayableInvoice>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var selection by remember { mutableStateOf<Set<String>>(emptySet()) }
    var reference by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }

    suspend fun load() {
        try {
            invoices = repository.payableInvoices()
            selection = selection.intersect(invoices.map { it.invoiceId }.toSet())
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        loaded = true
    }

    fun pay() {
        working = true
        scope.launch {
            try {
                repository.payBatch(selection.toList(), reference.ifEmpty { null })
                selection = emptySet()
                reference = ""
                load()
            } catch (e: Exception) {
                error = e.message
            }
            working = false
        }
    }

    LaunchedEffect(repository) { load() }

    FullScreenSheet("", onDismiss, back = true, scrolls = false) {
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } },
            modifier = Modifier.fillMaxWidth().weight(1f),
        ) {
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                item { ScreenTitle("À régler") }
                when {
                    !loaded -> item { LoadingBlock() }
                    invoices.isEmpty() -> item {
                        Column(Modifier.fillMaxWidth().padding(vertical = 56.dp), horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                            Icon(Icons.Outlined.CheckCircle, null, tint = Palette.success, modifier = Modifier.size(40.dp))
                            Text("Aucune facture en attente de règlement", style = Type.body, color = Palette.textPrimary)
                        }
                    }
                    else -> {
                        item { TextLink("Tout sélectionner") { selection = PayableRules.selectAllPayable(invoices) } }
                        items(PayableRules.groups(invoices), key = { it.first }) { (apporteur, group) ->
                            Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                                Text(apporteur, style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                                group.forEach { invoice ->
                                    PayableRow(invoice, invoice.invoiceId in selection) {
                                        selection = if (invoice.invoiceId in selection) selection - invoice.invoiceId else selection + invoice.invoiceId
                                    }
                                }
                            }
                        }
                    }
                }
                error?.let { item { Text(it, style = Type.secondary, color = Palette.destructive) } }
                item { Spacer(Modifier.size(Spacing.l)) }
            }
        }

        if (selection.isNotEmpty()) {
            PayBar(
                count = selection.size,
                total = Money.euros(PayableRules.selectedTotal(invoices, selection)),
                reference = reference,
                onReference = { reference = it },
                working = working,
                canPay = PayableRules.canPay(invoices, selection, working),
                onPay = { confirming = true },
            )
        }
    }

    if (confirming) {
        ConfirmDialog(
            title = "Régler ${selection.size} facture(s) ?",
            message = "Les factures passeront au statut réglé et les apporteurs seront notifiés. Cette opération est enregistrée et ne peut pas être annulée.",
            confirm = "Confirmer le règlement",
            onConfirm = { confirming = false; pay() },
            onDismiss = { confirming = false },
        )
    }
}

@Composable
private fun PayableRow(invoice: PayableInvoice, selected: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .alpha(if (invoice.hasBankDetails) 1f else 0.55f)
            .clickable(enabled = invoice.hasBankDetails, role = Role.Checkbox, onClick = onToggle)
            .semantics { this.selected = selected },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Icon(if (selected) Icons.Filled.CheckCircle else Icons.Outlined.Circle, null,
            tint = if (selected) Palette.brand else Palette.pendingRing, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(invoice.number, style = Type.body, color = Palette.textPrimary)
            Text(invoice.filleul, style = Type.secondary, color = Palette.textSecondary)
            if (!invoice.hasBankDetails) Text("Coordonnées bancaires manquantes", style = Type.caption, color = Palette.destructive)
        }
        Text(Money.euros(invoice.amountTtc), style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
    }
}

@Composable
private fun PayBar(count: Int, total: String, reference: String, onReference: (String) -> Unit, working: Boolean, canPay: Boolean, onPay: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(bottom = Spacing.m).cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("$count sélectionnée(s)", style = Type.secondary, color = Palette.textSecondary, modifier = Modifier.weight(1f))
            Text(total, style = Type.cardTitle, color = Palette.textPrimary)
        }
        val shape = RoundedCornerShape(10.dp)
        Box(Modifier.fillMaxWidth().background(Palette.track, shape).border(1.dp, Palette.hairline, shape).padding(horizontal = Spacing.m, vertical = 10.dp)) {
            if (reference.isEmpty()) Text("Référence du virement (facultatif)", style = Type.secondary, color = Palette.textSecondary)
            BasicTextField(reference, onReference, singleLine = true, textStyle = Type.secondary.copy(color = Palette.textPrimary),
                cursorBrush = SolidColor(Palette.brand), modifier = Modifier.fillMaxWidth())
        }
        PrimaryActionButton(if (working) "Règlement…" else "Régler", enabled = canPay, working = working, onClick = onPay)
    }
}
