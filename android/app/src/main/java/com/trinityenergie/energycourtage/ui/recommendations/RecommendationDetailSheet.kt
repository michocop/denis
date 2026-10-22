package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowCircleRight
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Money
import com.trinityenergie.energycourtage.data.DocumentsRepository
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.RecoDates
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.model.Stage
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.documents.LeadDocumentsSection
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import kotlinx.coroutines.launch
import java.math.BigDecimal

/** The commission as typed: a comma or a point, spaces allowed ("1 000,50").
 *  Null unless it is a positive amount. */
fun parseCommission(text: String): BigDecimal? {
    val normalised = text.trim().replace(" ", "").replace(" ", "").replace(" ", "").replace(",", ".")
    val amount = normalised.toBigDecimalOrNull() ?: return null
    return if (amount > BigDecimal.ZERO) amount else null
}

/**
 * "Voir plus": the full record behind a card (iOS RecommendationDetailView).
 * An admin sets the commission here while no invoice exists -- the invoice
 * copies it, and a mistake after that is corrected by an avoir -- and hands
 * the lead to another administrator.
 */
@Composable
fun RecommendationDetailSheet(
    recommendation: Recommendation,
    pipeline: List<Stage>,
    admins: List<Profile>,
    documents: DocumentsRepository,
    onDismiss: () -> Unit,
    onOpenInvoice: () -> Unit,
    onOpenNotes: () -> Unit,
    /** Admin only; null hides the choice. */
    onReassign: (suspend (adminId: String) -> Unit)?,
    /** Admin only; null hides the editor. */
    onSetAmount: (suspend (BigDecimal) -> Unit)?,
) {
    val scope = rememberCoroutineScope()
    var amountText by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var reassigning by remember { mutableStateOf<String?>(null) }

    FullScreenSheet(title = recommendation.filleulName, onDismiss = onDismiss) {
        if (recommendation.daysSinceActivity >= 7) StalenessBanner(recommendation.daysSinceActivity)

        DetailSection("Filleul") {
            DetailRow("Nom", recommendation.filleulName)
            recommendation.filleulPhone?.let { DetailRow("Téléphone", it) }
        }

        recommendation.apporteurComment?.takeIf { it.isNotEmpty() }?.let { comment ->
            DetailSection("Commentaire de l'apporteur") {
                SelectionContainer { Text(comment, style = Type.body, color = Palette.textPrimary) }
            }
        }

        DetailSection("Suivi") {
            DetailRow("Recommandé par", recommendation.parrainName)
            DetailRow("Créée le", RecoDates.relativeDate(recommendation.createdAt))
            DetailRow("Étape", pipeline.firstOrNull { it.id == recommendation.currentStageId }?.label ?: "—")
            DetailRow("Statut", recommendation.statusLabel)
        }

        DetailSection("Récompense") {
            DetailRow("Montant", recommendation.rewardAmount?.let { Money.euros(it) } ?: "—")
            DetailRow("État", recommendation.rewardLabel)
            recommendation.invoiceNumber?.let { DetailRow("Facture", it) }
            // the invoice copies the amount: past it, a mistake is corrected by an avoir
            if (onSetAmount != null && recommendation.invoiceNumber == null) {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    HorizontalDivider(color = Palette.hairline)
                    LabelledField(
                        label = "Définir la commission (€)",
                        value = amountText,
                        onValueChange = { text -> amountText = text.filter { it.isDigit() || it == ',' || it == '.' || it == ' ' } },
                        placeholder = "0",
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        enabled = !working,
                    )
                    val amount = parseCommission(amountText)
                    val enabled = !working && amountText.isNotBlank()
                    Text(
                        if (working) "Enregistrement…" else "Enregistrer le montant",
                        style = Type.body, color = Palette.brand,
                        modifier = Modifier.alpha(if (enabled) 1f else 0.45f)
                            .clickable(enabled = enabled, role = Role.Button) {
                                // a comma or a point: a French keyboard gives a comma
                                val value = amount ?: return@clickable
                                scope.launch {
                                    working = true
                                    try { onSetAmount(value); amountText = "" } finally { working = false }
                                }
                            }
                            .padding(vertical = Spacing.xs),
                    )
                }
            }
        }

        LeadDocumentsSection(recommendation.id, documents)

        if (onReassign != null && admins.isNotEmpty()) {
            DetailSection("Suivi par") {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    admins.forEach { admin ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable(enabled = reassigning == null, role = Role.Button) {
                                    scope.launch {
                                        reassigning = admin.id
                                        try { onReassign(admin.id) } finally { reassigning = null }
                                    }
                                }
                                .padding(vertical = Spacing.xs),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(admin.fullName, style = Type.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                            if (reassigning == admin.id) CircularProgressIndicator(Modifier.size(20.dp), color = Palette.brand, strokeWidth = 2.dp)
                            else Icon(Icons.Outlined.ArrowCircleRight, null, tint = Palette.brand)
                        }
                    }
                }
            }
        }

        SecondaryActionButton("Notes personnelles", icon = Icons.Outlined.Description, onClick = onOpenNotes)
        if (recommendation.invoiceNumber != null) {
            SecondaryActionButton("Voir le contrat", icon = Icons.AutoMirrored.Outlined.Article, onClick = onOpenInvoice)
        }
    }
}

/**
 * The private notes editor (iOS PersonalNotesView). Saved on "Enregistrer";
 * if that fails the sheet stays open with the text in it, rather than closing
 * as if the note had been kept.
 */
@Composable
fun PersonalNotesSheet(initialBody: String, onDismiss: () -> Unit, save: suspend (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var body by remember { mutableStateOf(initialBody) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    val canSave = !saving && body != initialBody

    FullScreenSheet(
        title = "Notes personnelles",
        onDismiss = onDismiss,
        scrolls = false,
        actions = {
            if (saving) CircularProgressIndicator(Modifier.size(20.dp), color = Palette.brand, strokeWidth = 2.dp)
            else Text("Enregistrer", style = Type.label, color = Palette.brand,
                modifier = Modifier.alpha(if (canSave) 1f else 0.4f).clickable(enabled = canSave, role = Role.Button) {
                    scope.launch {
                        saving = true
                        try {
                            save(body)
                            onDismiss()
                        } catch (e: Exception) {
                            error = "La note n'a pas pu être enregistrée : ${e.message}"
                        }
                        saving = false
                    }
                }.padding(Spacing.xs))
        },
    ) {
        Text("Ces notes ne sont visibles que par vous.", style = Type.secondary, color = Palette.textSecondary)
        Box(
            Modifier.fillMaxWidth().weight(1f).heightIn(min = 160.dp)
                .background(Palette.track, RoundedCornerShape(Radius.field))
                .clickable(indication = null, interactionSource = null) { runCatching { focus.requestFocus() } }
                .padding(Spacing.m),
        ) {
            BasicTextField(
                value = body, onValueChange = { body = it },
                textStyle = Type.body.copy(color = Palette.textPrimary),
                cursorBrush = SolidColor(Palette.brand),
                modifier = Modifier.fillMaxSize().focusRequester(focus),
            )
        }
        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
        Box(Modifier.height(Spacing.s))
    }
}
