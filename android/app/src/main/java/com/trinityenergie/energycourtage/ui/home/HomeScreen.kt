package com.trinityenergie.energycourtage.ui.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Draw
import androidx.compose.material.icons.filled.HourglassBottom
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Money
import com.trinityenergie.energycourtage.data.ProfileRepository
import com.trinityenergie.energycourtage.model.DashboardStats
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.UserRole
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.BrandGradient
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.TrinityWordmark
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay

/**
 * Accueil: a dashboard read at a glance, one screen, no scrolling
 * (Features/Home/HomeView.swift). Figures reload each time the tab comes
 * back into view.
 */
@Composable
fun HomeScreen(
    profiles: ProfileRepository,
    refreshKey: Int,
    accessory: @Composable () -> Unit,
    onOpenMandate: (() -> Unit)?,
    onNewRecommendation: () -> Unit,
) {
    var stats by remember { mutableStateOf(DashboardStats()) }
    var profile by remember { mutableStateOf<Profile?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var appeared by remember { mutableStateOf(false) }

    LaunchedEffect(refreshKey) {
        try {
            coroutineScope {
                val s = async { profiles.dashboardStats() }
                val p = async { profiles.currentProfile() }
                stats = s.await(); profile = p.await()
            }
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        appeared = true
    }

    BrandBackground {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = Spacing.gutter).padding(bottom = Spacing.l),
            verticalArrangement = Arrangement.spacedBy(Spacing.l),
        ) {
            Row(Modifier.fillMaxWidth().padding(top = Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                TrinityWordmark(logoSize = 20.dp)
                Spacer(Modifier.weight(1f))
                accessory()
            }

            Rise(appeared, 1) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        buildAnnotatedString {
                            withStyle(SpanStyle(color = Palette.textPrimary)) { append("Bonjour, ") }
                            withStyle(SpanStyle(brush = BrandGradient)) { append(profile?.firstName ?: "") }
                        },
                        style = Type.screenTitle, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Text("Voici où en sont vos recommandations.", style = Type.secondary, color = Palette.textSecondary, maxLines = 1)
                }
            }

            // The mandate gate is surfaced here rather than at invoicing time:
            // without it no invoice can be issued, so the apporteur should
            // learn that before earning anything.
            val p = profile
            if (p != null && !p.canBeInvoiced && p.role == UserRole.Apporteur) {
                Rise(appeared, 2) { MandateNotice(onOpenMandate) }
            }

            Column(Modifier.fillMaxWidth().weight(1f, fill = false).heightIn(max = 330.dp), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    StatTile("Recommandations actives", "${stats.activeCount}", Palette.brand, Icons.Filled.Bolt, appeared, 3)
                    StatTile("Taux de conversion", "%.0f %%".format(stats.conversionRate), Palette.brand, Icons.AutoMirrored.Filled.TrendingUp, appeared, 4)
                }
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    StatTile("En attente", Money.euros(stats.pendingTotal), Palette.ice, Icons.Filled.HourglassBottom, appeared, 5)
                    StatTile("Gagné", Money.euros(stats.earnedTotal), Palette.successText, Icons.Filled.Verified, appeared, 6)
                }
            }

            Spacer(Modifier.weight(0.001f))
            error?.let { Text(it, style = Type.secondary, color = Palette.destructive, maxLines = 2) }
            Rise(appeared, 7) { PrimaryActionButton("Nouvelle recommandation", onClick = onNewRecommendation) }
        }
    }
}

/** Each part rises in on its own step of the cascade (iOS staggeredAppear:
 *  a spring, 45 ms per step). */
@Composable
private fun Rise(visible: Boolean, index: Int, content: @Composable () -> Unit) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(visible) { if (visible) { delay(45L * index); shown = true } }
    AnimatedVisibility(
        shown,
        enter = fadeIn(spring(stiffness = Spring.StiffnessLow)) +
            slideInVertically(spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessLow)) { it / 6 },
    ) { content() }
}

/** A figure with what it counts; the label reserves two lines so a row's
 *  figures line up whatever the labels' lengths. */
@Composable
private fun RowScope.StatTile(label: String, value: String, tint: Color, icon: ImageVector, appeared: Boolean, index: Int) {
    Box(Modifier.weight(1f).fillMaxHeight()) {
        Rise(appeared, index) {
            Column(
                Modifier.fillMaxSize().cardSurface().padding(Spacing.l),
                verticalArrangement = Arrangement.spacedBy(Spacing.s),
            ) {
                Box(Modifier.size(26.dp).background(tint.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(icon, null, tint = tint, modifier = Modifier.size(14.dp))
                }
                Text(label, style = Type.caption, color = Palette.textSecondary, minLines = 2, maxLines = 2)
                Spacer(Modifier.weight(1f))
                Text(value, style = Type.statValue, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Self-billing needs a prior mandate, so this blocks payment, not a form. */
@Composable
private fun MandateNotice(onOpen: (() -> Unit)?) {
    val shape = RoundedCornerShape(Radius.card)
    Row(
        Modifier.fillMaxWidth()
            .background(Palette.rewardSoft, shape)
            .border(1.dp, Palette.rewardText.copy(alpha = 0.25f), shape)
            .then(if (onOpen != null) Modifier.clickable(onClick = onOpen) else Modifier)
            .padding(horizontal = Spacing.l, vertical = Spacing.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Box(Modifier.size(34.dp).background(Palette.rewardText.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Draw, null, tint = Palette.rewardText, modifier = Modifier.size(16.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Mandat de facturation à signer", style = Type.label, color = Palette.textPrimary, maxLines = 1)
            Text("Requis pour recevoir vos gains.", style = Type.caption, color = Palette.textSecondary, maxLines = 1)
        }
        if (onOpen != null) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.rewardText)
    }
}
