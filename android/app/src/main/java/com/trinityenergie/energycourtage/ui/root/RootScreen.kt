package com.trinityenergie.energycourtage.ui.root

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.AppModel
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.home.HomeScreen
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.brandGlass

private enum class Tab(val label: String, val icon: ImageVector, val selected: ImageVector) {
    Home("Accueil", Icons.Outlined.Home, Icons.Filled.Home),
    Recommendations("Reco", Icons.Outlined.ViewAgenda, Icons.Filled.ViewAgenda),
    Chat("Chat", Icons.Outlined.ChatBubbleOutline, Icons.Filled.ChatBubble),
    Profile("Profil", Icons.Outlined.PersonOutline, Icons.Filled.Person),
}

/** The four tabs, as on iOS: Accueil, Reco, Chat, Profil. */
@Composable
fun RootScreen(ready: AppModel.Phase.Ready, onSignOut: () -> Unit) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var homeRefresh by rememberSaveable { mutableIntStateOf(0) }

    Scaffold(
        containerColor = Palette.night,
        // each screen paints its own glow up to the top edge, under the status bar
        contentWindowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        bottomBar = {
            NavigationBar(containerColor = Palette.night.copy(alpha = 0.96f), tonalElevation = 0.dp) {
                Tab.entries.forEachIndexed { i, t ->
                    NavigationBarItem(
                        selected = tab == i,
                        onClick = { if (i == 0 && tab != 0) homeRefresh++; tab = i },
                        icon = { Icon(if (tab == i) t.selected else t.icon, null) },
                        label = { Text(t.label, style = Type.caption) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = Palette.brand, selectedTextColor = Palette.brand,
                            unselectedIconColor = Palette.textSecondary, unselectedTextColor = Palette.textSecondary,
                            indicatorColor = Palette.brandSoft,
                        ),
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (Tab.entries[tab]) {
                Tab.Home -> HomeScreen(
                    profiles = ready.deps.profiles,
                    refreshKey = homeRefresh,
                    accessory = { Bell() },
                    onOpenMandate = null,
                    onNewRecommendation = { tab = Tab.Recommendations.ordinal },
                )
                Tab.Profile -> ComingSoon("Profil", "Votre profil, vos documents et la déconnexion arrivent dans la prochaine version Android.") {
                    TextLink("Se déconnecter", onClick = onSignOut)
                }
                else -> ComingSoon(Tab.entries[tab].label, "Cet écran arrive dans la prochaine version Android.")
            }
        }
    }
}

@Composable
private fun Bell() {
    Box(Modifier.size(40.dp).brandGlass(), contentAlignment = Alignment.Center) {
        Icon(Icons.Outlined.Notifications, "Notifications", tint = Palette.textPrimary, modifier = Modifier.size(20.dp))
    }
}

/** Placeholder for the tabs still being ported (docs/ANDROID.md, lots 2–4). */
@Composable
private fun ComingSoon(title: String, body: String, extra: @Composable () -> Unit = {}) {
    BrandBackground {
        Column(
            Modifier.fillMaxSize().padding(Spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Spacing.m, Alignment.CenterVertically),
        ) {
            Text(title, style = Type.screenTitle, color = Palette.textPrimary)
            Text(body, style = Type.body, color = Palette.textSecondary, textAlign = TextAlign.Center)
            extra()
        }
    }
}

