package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.trinityenergie.energycourtage.model.RecoStrings
import com.trinityenergie.energycourtage.model.RecommendationFilter
import com.trinityenergie.energycourtage.ui.theme.Manrope
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface

/** "De nouveaux éléments sont disponibles · Actualiser": raised by the poll
 *  rather than reloading the list under the reader's finger. */
@Composable
fun RefreshBanner(onRefresh: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().cardSurface(28.dp).padding(horizontal = Spacing.l, vertical = Spacing.m),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("De nouveaux éléments sont disponibles", style = Type.secondary, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(Spacing.s))
        Row(
            Modifier.background(Palette.brandFill, RoundedCornerShape(50)).clickable(role = Role.Button, onClick = onRefresh)
                .padding(horizontal = Spacing.l, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Filled.Autorenew, null, tint = Color.White, modifier = Modifier.size(18.dp))
            Text("Actualiser", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Color.White)
        }
    }
}

/** The message an admin left on a stage, read from the bubble. */
@Composable
fun StageCommentDialog(stageLabel: String, message: String, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier.padding(horizontal = Spacing.gutter).fillMaxWidth()
                .background(Palette.surface, RoundedCornerShape(Radius.modal)).padding(Spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Spacing.l),
        ) {
            Box(Modifier.size(56.dp).background(Palette.brandSoft, CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Outlined.Chat, null, tint = Palette.brand, modifier = Modifier.size(24.dp))
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                val title = Type.body.copy(fontFamily = Manrope, fontSize = 21.sp, lineHeight = 27.sp)
                Text("Commentaire pour l'étape", style = title, color = Palette.textPrimary, textAlign = TextAlign.Center)
                Text("\"$stageLabel\"", style = title, color = Palette.textPrimary, textAlign = TextAlign.Center)
            }
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                Text("Message", style = Type.label, color = Palette.textPrimary)
                Box(Modifier.fillMaxWidth().heightIn(max = 320.dp).background(Palette.track, RoundedCornerShape(Radius.field))
                    .verticalScroll(rememberScrollState()).padding(Spacing.l)) {
                    Text(message, style = Type.body, color = Palette.textPrimary)
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Text("Fermer", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Color.White,
                    modifier = Modifier.background(Palette.brand, RoundedCornerShape(Radius.button))
                        .clickable(role = Role.Button, onClick = onClose).padding(horizontal = 32.dp, vertical = 14.dp))
            }
        }
    }
}

/** A recommendation gone quiet: what an admin needs to notice. */
@Composable
fun StalenessBanner(days: Int) {
    Row(
        Modifier.fillMaxWidth().background(Palette.staleSoft, RoundedCornerShape(10.dp)).padding(Spacing.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Icon(Icons.Outlined.Schedule, null, tint = Palette.staleText, modifier = Modifier.size(20.dp))
        Text(RecoStrings.idleFor(days), style = Type.secondary, color = Palette.staleText)
    }
}

/** Amber when the lead is merely contested, red when it is already yours. */
@Composable
fun DuplicateWarning(text: String, blocking: Boolean) {
    Row(
        Modifier.fillMaxWidth()
            .background(if (blocking) Palette.destructive.copy(alpha = 0.12f) else Palette.rewardSoft, RoundedCornerShape(Radius.field))
            .padding(Spacing.l)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Icon(if (blocking) Icons.Filled.Report else Icons.Filled.Warning, null,
            tint = if (blocking) Palette.destructive else Palette.rewardText, modifier = Modifier.size(20.dp))
        Text(text, style = Type.secondary, color = Palette.textPrimary)
    }
}

/** The shape of a card -- avatar, name, subtitle, progress -- so the real one
 *  lands where the placeholder was. */
@Composable
fun SkeletonCard() {
    val pulse by rememberInfiniteTransition(label = "shimmer").animateFloat(
        0.45f, 1f, infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Reverse), label = "alpha")
    Column(
        Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding).clearAndSetSemantics {},
        verticalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.alpha(pulse)) {
            Box(Modifier.size(42.dp).background(Palette.track, CircleShape))
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                Box(Modifier.size(160.dp, 20.dp).background(Palette.track, RoundedCornerShape(6.dp)))
                Box(Modifier.size(120.dp, 12.dp).background(Palette.track, RoundedCornerShape(6.dp)))
            }
        }
        Box(Modifier.fillMaxWidth().alpha(pulse).heightIn(min = 10.dp, max = 10.dp).background(Palette.track, RoundedCornerShape(6.dp)))
    }
}

@Composable
fun RecoEmptyState(filter: RecommendationFilter, hasQuery: Boolean) {
    Column(Modifier.fillMaxWidth().padding(vertical = 56.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Icon(if (hasQuery) Icons.Filled.Search else Icons.Filled.Inbox, null, tint = Palette.textSecondary, modifier = Modifier.size(34.dp))
        Text(
            if (hasQuery) "Aucun résultat"
            else if (filter == RecommendationFilter.Active) "Aucune recommandation active" else "Aucune recommandation archivée",
            style = Type.body, color = Palette.textPrimary, textAlign = TextAlign.Center)
        Text(if (hasQuery) "Essayez un autre nom." else "Vos recommandations apparaîtront ici dès leur création.",
            style = Type.secondary, color = Palette.textSecondary, textAlign = TextAlign.Center)
    }
}

@Composable
fun RecoErrorState(message: String, onRetry: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 48.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Icon(Icons.Outlined.WarningAmber, null, tint = Palette.destructive, modifier = Modifier.size(34.dp))
        Text("Chargement impossible", style = Type.body, color = Palette.textPrimary)
        Text(message, style = Type.secondary, color = Palette.textSecondary, textAlign = TextAlign.Center)
        Text("Réessayer", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.brand,
            modifier = Modifier.clickable(role = Role.Button, onClick = onRetry).padding(Spacing.s))
    }
}

/** A titled glass section of the detail screen. */
@Composable
fun DetailSection(title: String, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text(title, style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
        content()
    }
}

@Composable
fun DetailRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Text(label, style = Type.secondary, color = Palette.textSecondary)
        Spacer(Modifier.width(Spacing.l))
        Text(value, style = Type.body, color = Palette.textPrimary, textAlign = TextAlign.End, modifier = Modifier.weight(1f))
    }
}

