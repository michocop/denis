package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.CardGiftcard
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.model.StageRow
import com.trinityenergie.energycourtage.model.StageState
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type

private val NodeSize = 32.dp
private val ConnectorHeight = 30.dp
private val ConnectorWidth = 3.dp

/**
 * The vertical pipeline timeline (iOS DesignSystem/StageStepper.swift): the
 * four node treatments, and the connector rule -- the segment under a step is
 * green only when that step is completed, so the green thread stops exactly
 * where progress stops.
 */
@Composable
fun StageStepper(rows: List<StageRow>, onComment: (StageRow) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        rows.forEachIndexed { index, row ->
            Row(
                Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = accessibilityLabel(row) },
                horizontalArrangement = Arrangement.spacedBy(Spacing.m),
            ) {
                Column(Modifier.width(NodeSize), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    Node(row.state)
                    if (index != rows.lastIndex) {
                        Box(Modifier.width(ConnectorWidth).height(ConnectorHeight).background(
                            if (row.state == StageState.Completed) Palette.success else Palette.connectorIdle,
                            RoundedCornerShape(50)))
                    }
                }
                StageRowContent(row, onComment, Modifier.weight(1f))
            }
        }
    }
}

/** The label, then the reward pill and the comment bubble at the end. The
 *  pill keeps its word when the row has room and shrinks to the gift when the
 *  stage name is long, as iOS's ViewThatFits. */
@Composable
private fun StageRowContent(row: StageRow, onComment: (StageRow) -> Unit, modifier: Modifier) {
    val labelColor = if (row.state == StageState.Pending) Palette.textSecondary else Palette.textPrimary
    SubcomposeLayout(modifier.height(NodeSize)) { constraints ->
        val max = constraints.maxWidth
        val gap = Spacing.s.roundToPx()
        val loose = Constraints()
        val comment = if (row.comment != null) subcompose("comment") {
            Icon(Icons.AutoMirrored.Outlined.Chat, "Commentaire pour l'étape ${row.label}", tint = Palette.brand,
                modifier = Modifier.size(36.dp).clickable(role = Role.Button) { onComment(row) }.padding(7.dp))
        }.first().measure(loose) else null
        val commentWidth = comment?.let { it.width + gap } ?: 0
        val natural = subcompose("natural") { Text(row.label, style = Type.body, maxLines = 1) }.first().measure(loose).width
        val badge = if (row.showsReward) {
            val full = subcompose("full") { RewardBadge(showsWord = true) }.first().measure(loose)
            if (natural + gap + full.width + commentWidth <= max) full
            else subcompose("compact") { RewardBadge(showsWord = false) }.first().measure(loose)
        } else null
        val badgeWidth = badge?.let { it.width + gap } ?: 0
        val labelMax = (max - badgeWidth - commentWidth).coerceAtLeast(0)
        val label = subcompose("label") {
            Text(row.label, style = Type.body, color = labelColor, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }.first().measure(Constraints(maxWidth = labelMax))
        val height = NodeSize.roundToPx()
        layout(max, height) {
            label.placeRelative(0, (height - label.height) / 2)
            var x = max
            comment?.let { x -= it.width; it.placeRelative(x, (height - it.height) / 2); x -= gap }
            badge?.let { x -= it.width; it.placeRelative(x, (height - it.height) / 2) }
        }
    }
}

@Composable
private fun Node(state: StageState) {
    when (state) {
        StageState.Completed -> Box(Modifier.size(NodeSize).background(Palette.success, CircleShape), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Check, null, tint = Color.White, modifier = Modifier.size(18.dp))
        }
        StageState.Current -> Box(Modifier.size(NodeSize).background(Palette.surface, CircleShape).border(3.dp, Palette.brand, CircleShape),
            contentAlignment = Alignment.Center) {
            Box(Modifier.size(11.dp).background(Palette.brand, CircleShape))
        }
        StageState.Pending -> Box(Modifier.size(NodeSize), contentAlignment = Alignment.Center) {
            Box(Modifier.size(NodeSize - 4.dp).background(Palette.surface, CircleShape).border(1.5.dp, Palette.pendingRing, CircleShape),
                contentAlignment = Alignment.Center) {
                Box(Modifier.size(7.dp).background(Palette.pendingRing, CircleShape))
            }
        }
        StageState.Failed -> Box(Modifier.size(NodeSize).background(Palette.destructive, CircleShape), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Close, null, tint = Color.White, modifier = Modifier.size(17.dp))
        }
    }
}

private fun accessibilityLabel(row: StageRow): String {
    val status = when (row.state) {
        StageState.Completed -> "terminée"
        StageState.Current -> "en cours"
        StageState.Pending -> "à venir"
        StageState.Failed -> "échouée"
    }
    return "${row.label}, étape $status"
}

/** The gift pill pinned to the reward-triggering stage. It is stage
 *  configuration, so it shows whether or not that stage has been reached. */
@Composable
fun RewardBadge(showsWord: Boolean = true) {
    Row(
        Modifier
            .background(Palette.rewardSoft, RoundedCornerShape(50))
            .padding(horizontal = if (showsWord) 12.dp else 9.dp, vertical = 7.dp)
            .clearAndSetSemantics { contentDescription = "Cette étape déclenche la récompense" },
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.CardGiftcard, null, tint = Palette.rewardText, modifier = Modifier.size(13.dp))
        if (showsWord) Text("Récompense", style = Type.badge, color = Palette.rewardText, maxLines = 1)
    }
}
