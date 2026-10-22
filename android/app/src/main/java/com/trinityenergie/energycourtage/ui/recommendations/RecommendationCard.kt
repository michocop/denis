package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Money
import com.trinityenergie.energycourtage.model.RecoDates
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.model.Stage
import com.trinityenergie.energycourtage.model.StageRow
import com.trinityenergie.energycourtage.model.UserRole
import com.trinityenergie.energycourtage.model.stepperRows
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.components.StatusBanner
import com.trinityenergie.energycourtage.ui.components.TertiaryActionButton
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlin.math.roundToInt

/**
 * The expandable recommendation card (iOS RecommendationCard). Collapsed:
 * identity, referrer, day, where the lead stands and -- once the reward is
 * triggered -- the green amount. Expanded: the banner, the timeline and the
 * footer, which differs by role: an apporteur reads, an admin also gets
 * "Valider l'étape". A long press opens the admin's action sheet.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun RecommendationCard(
    recommendation: Recommendation,
    pipeline: List<Stage>,
    role: UserRole,
    expanded: Boolean,
    validating: Boolean,
    onToggle: () -> Unit,
    onComment: (StageRow) -> Unit,
    onNotes: () -> Unit,
    onContract: () -> Unit,
    onMore: () -> Unit,
    onValidate: () -> Unit,
    onLongPress: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val longPress: (() -> Unit)? = onLongPress?.let { action -> { haptics.performHapticFeedback(HapticFeedbackType.LongPress); action() } }
    val quiet = remember { MutableInteractionSource() }

    Column(
        modifier
            .fillMaxWidth()
            .cardSurface()
            .then(if (longPress != null) Modifier.combinedClickable(quiet, null, onLongClickLabel = "Gérer la recommandation",
                onLongClick = longPress, onClick = {}) else Modifier)
            .padding(Spacing.cardPadding),
        verticalArrangement = Arrangement.spacedBy(Spacing.l),
    ) {
        Header(recommendation, pipeline, expanded, onToggle, longPress)

        AnimatedVisibility(expanded, enter = expandVertically(spring(dampingRatio = 0.9f)) + fadeIn(),
            exit = shrinkVertically(spring(dampingRatio = 0.9f)) + fadeOut()) {
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                recommendation.bannerText(pipeline)?.let { StatusBanner(it) }
                StageStepper(recommendation.stepperRows(pipeline), onComment)
                Footer(recommendation, pipeline, role, validating, onNotes, onContract, onMore, onValidate)
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Header(
    recommendation: Recommendation,
    pipeline: List<Stage>,
    expanded: Boolean,
    onToggle: () -> Unit,
    onLongPress: (() -> Unit)?,
) {
    val rotation by animateFloatAsState(if (expanded) 180f else 0f, label = "chevron")
    val progress = recommendation.progress(pipeline)
    val tint = when (recommendation.stageTint(pipeline)) {
        Recommendation.Tint.Destructive -> Palette.destructive
        Recommendation.Tint.Success -> Palette.successText
        Recommendation.Tint.Brand -> Palette.brand
    }
    Column(
        Modifier.fillMaxWidth().combinedClickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
            onClick = onToggle, onLongClick = onLongPress, onLongClickLabel = if (onLongPress != null) "Gérer la recommandation" else null),
        verticalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Box(
                Modifier.size(42.dp).background(Palette.avatar, CircleShape).border(1.dp, Palette.brand.copy(alpha = 0.35f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { Text(recommendation.initials, style = Type.badge, color = Palette.textPrimary) }

            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(recommendation.filleulName, style = Type.cardTitle, color = Palette.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("Par ${recommendation.parrainName} · ${RecoDates.relativeDay(recommendation.createdAt)}",
                    style = Type.caption, color = Palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }

            Box(
                Modifier.size(32.dp).background(Palette.grouped, CircleShape).clickable(role = Role.Button, onClick = onToggle)
                    .semantics { contentDescription = if (expanded) "Réduire" else "Développer" },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.KeyboardArrowDown, null, tint = Palette.textSecondary, modifier = Modifier.size(20.dp).rotate(rotation))
            }
        }

        // where the lead stands, at a glance
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            recommendation.currentStageLabel(pipeline)?.let { label ->
                Text(label, style = Type.caption.copy(fontWeight = FontWeight.SemiBold), color = tint, maxLines = 1,
                    modifier = Modifier.background(tint.copy(alpha = 0.14f), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 5.dp))
            }
            LinearProgressIndicator(
                progress = { progress.toFloat() },
                modifier = Modifier.weight(1f).height(4.dp).semantics { contentDescription = "Avancement ${(progress * 100).roundToInt()} %" },
                color = tint, trackColor = Palette.track, strokeCap = StrokeCap.Round, gapSize = 0.dp, drawStopIndicator = {},
            )
            recommendation.displayedAmount?.let { amount ->
                Text(Money.euros(amount), style = Type.amount, color = Palette.successText, maxLines = 1,
                    modifier = Modifier.semantics { contentDescription = "Récompense ${Money.euros(amount)}" })
            }
        }
    }
}

@Composable
private fun Footer(
    recommendation: Recommendation,
    pipeline: List<Stage>,
    role: UserRole,
    validating: Boolean,
    onNotes: () -> Unit,
    onContract: () -> Unit,
    onMore: () -> Unit,
    onValidate: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SecondaryActionButton("Notes personnelles", icon = Icons.Outlined.Description, onClick = onNotes)
        if (recommendation.hasContract) {
            SecondaryActionButton("Voir le contrat", icon = Icons.AutoMirrored.Outlined.Article, onClick = onContract)
        }
        if (role.isAdmin && !recommendation.status.isArchived && !recommendation.isPipelineComplete(pipeline)) {
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                TertiaryActionButton("Voir plus", modifier = Modifier.weight(1f), onClick = onMore)
                PrimaryActionButton("Valider l'étape", modifier = Modifier.weight(1f), working = validating, onClick = onValidate)
            }
        } else {
            TertiaryActionButton("Voir plus", onClick = onMore)
        }
    }
}
