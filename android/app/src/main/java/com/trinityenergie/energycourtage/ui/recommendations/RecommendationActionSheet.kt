package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.automirrored.outlined.CompareArrows
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.automirrored.outlined.NoteAdd
import androidx.compose.material.icons.outlined.NotificationsNone
import androidx.compose.material.icons.outlined.PersonRemove
import androidx.compose.material.icons.outlined.Phone
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.model.RecoDates
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.ui.components.ConfirmDialog
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type

/** The admin's powers over one recommendation. */
enum class RecoAction {
    Reassign, Reminders, Appointment, Reset, ArchiveWon, ArchiveLost, Delete, IssueInvoice, EraseFilleul;

    /** The confirmation each irreversible action asks first, in the iOS copy. */
    val confirmTitle get() = when (this) {
        Reset -> "Remettre le suivi à zéro ?"
        ArchiveWon -> "Clôturer comme gagnée ?"
        ArchiveLost -> "Clôturer comme perdue ?"
        Delete -> "Supprimer cette recommandation ?"
        IssueInvoice -> "Établir la facture ?"
        EraseFilleul -> "Effacer les données du filleul ?"
        else -> ""
    }

    val confirmMessage get() = when (this) {
        Reset -> "Toutes les étapes validées seront annulées. L'historique est conservé."
        ArchiveWon -> "Elle passera dans l'onglet Archivées. La commission est conservée."
        ArchiveLost -> "Elle passera dans l'onglet Archivées et la commission sera annulée, sauf si elle a déjà été facturée."
        Delete -> "Elle disparaîtra des listes. Si une facture existe, elle est conservée : la loi impose de garder les factures dix ans."
        IssueInvoice -> "La facture sera établie au montant de la commission convenue, puis numérotée définitivement. Une erreur se corrige ensuite par un avoir, jamais par une modification."
        EraseFilleul -> "À la demande de la personne : son nom, ses coordonnées et ses documents seront effacés définitivement. Les factures déjà émises gardent leur copie, comme la loi l'impose."
        else -> ""
    }

    val confirmVerb get() = when (this) {
        Reset -> "Remettre à zéro"
        ArchiveWon -> "Affaire gagnée"
        ArchiveLost -> "Affaire perdue"
        Delete -> "Supprimer"
        IssueInvoice -> "Établir la facture"
        EraseFilleul -> "Effacer définitivement"
        else -> "Confirmer"
    }

    val isDestructive get() = this == ArchiveLost || this == Delete || this == EraseFilleul
}

/**
 * The admin action sheet: the filleul's details and the powers (iOS
 * RecommendationActionSheet). Every irreversible action confirms first;
 * "Supprimer" is a soft delete, since an invoice is legally retained.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecommendationActionSheet(recommendation: Recommendation, onDismiss: () -> Unit, onAction: (RecoAction) -> Unit) {
    val context = LocalContext.current
    val state = rememberModalBottomSheetState()
    var confirming by remember { mutableStateOf<RecoAction?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state, containerColor = Palette.surface,
        contentColor = Palette.textPrimary) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = Spacing.gutter).padding(bottom = Spacing.xl).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(Spacing.l),
        ) {
            // header
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(recommendation.filleulName, style = Type.cardTitle, color = Palette.textPrimary)
                    Text("Recommandé par ${recommendation.parrainName}", style = Type.secondary, color = Palette.textSecondary)
                    Text(RecoDates.relativeDate(recommendation.createdAt), style = Type.secondary, color = Palette.textSecondary)
                }
                IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "Fermer", tint = Palette.textPrimary) }
            }

            // details
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                Text("Informations filleul", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                recommendation.filleulPhone?.takeIf { it.isNotBlank() }?.let { phone ->
                    Row(
                        Modifier.fillMaxWidth().clickable(role = Role.Button) { Files.dial(context, phone) }
                            .semantics(mergeDescendants = true) { contentDescription = "Appeler ${recommendation.filleulName}" },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m),
                    ) {
                        Icon(Icons.Outlined.Phone, null, tint = Palette.textSecondary)
                        Text(phone, style = Type.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.textSecondary, modifier = Modifier.size(18.dp))
                    }
                }
                InfoRow(Icons.Outlined.CalendarToday, RecoDates.relativeDate(recommendation.createdAt))
                recommendation.appointmentAt?.let { InfoRow(Icons.Outlined.Event, "Rendez-vous ${RecoDates.appointment(it)}") }
                recommendation.apporteurComment?.takeIf { it.isNotEmpty() }?.let { comment ->
                    Row(Modifier.semantics(mergeDescendants = true) { contentDescription = "Commentaire de l'apporteur : $comment" },
                        horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                        Icon(Icons.AutoMirrored.Outlined.Chat, null, tint = Palette.textSecondary)
                        Text(comment, style = Type.body, color = Palette.textPrimary)
                    }
                }
                InfoRow(Icons.AutoMirrored.Outlined.Article, recommendation.invoiceNumber?.let { "Facture $it" } ?: "Aucune facture émise")
            }

            // actions
            Column(Modifier.fillMaxWidth().background(Palette.grouped, RoundedCornerShape(Radius.field))) {
                val rows = buildList {
                    if (recommendation.canIssueInvoice) add(Triple(RecoAction.IssueInvoice, "Établir la facture", Icons.AutoMirrored.Outlined.NoteAdd))
                    add(Triple(RecoAction.Reassign, "Réassigner", Icons.AutoMirrored.Outlined.CompareArrows))
                    add(Triple(RecoAction.Reminders, "Rappels", Icons.Outlined.NotificationsNone))
                    add(Triple(RecoAction.Appointment, "Rendez-vous", Icons.Outlined.Event))
                    add(Triple(RecoAction.Reset, "Remettre à zéro", Icons.Outlined.RestartAlt))
                    add(Triple(RecoAction.ArchiveWon, "Affaire gagnée", Icons.Outlined.Verified))
                    add(Triple(RecoAction.ArchiveLost, "Affaire perdue", Icons.Outlined.Archive))
                    add(Triple(RecoAction.Delete, "Supprimer", Icons.Outlined.Delete))
                    add(Triple(RecoAction.EraseFilleul, "Effacer les données du filleul", Icons.Outlined.PersonRemove))
                }
                rows.forEachIndexed { i, (action, title, icon) ->
                    val tint = when (action) {
                        RecoAction.IssueInvoice -> Palette.brand
                        RecoAction.Delete, RecoAction.EraseFilleul -> Palette.destructive
                        else -> Palette.textPrimary
                    }
                    ActionRow(title, icon, tint) {
                        when (action) {
                            // no confirmation: these open another screen
                            RecoAction.Reassign, RecoAction.Reminders, RecoAction.Appointment -> onAction(action)
                            else -> confirming = action
                        }
                    }
                    if (i != rows.lastIndex) HorizontalDivider(Modifier.padding(start = 56.dp), color = Palette.hairline)
                }
            }
        }
    }

    confirming?.let { action ->
        ConfirmDialog(
            title = action.confirmTitle,
            message = action.confirmMessage,
            confirm = action.confirmVerb,
            destructive = action.isDestructive,
            onConfirm = { confirming = null; onAction(action) },
            onDismiss = { confirming = null },
        )
    }
}

@Composable
private fun InfoRow(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Icon(icon, null, tint = Palette.textSecondary)
        Text(text, style = Type.body, color = Palette.textPrimary)
    }
}

@Composable
private fun ActionRow(title: String, icon: ImageVector, tint: Color, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(horizontal = Spacing.l, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
        Row(Modifier.width(Spacing.l)) {}
        Text(title, style = Type.body, color = tint)
    }
}
