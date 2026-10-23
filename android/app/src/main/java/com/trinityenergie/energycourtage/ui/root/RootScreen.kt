package com.trinityenergie.energycourtage.ui.root

import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.AppModel
import com.trinityenergie.energycourtage.core.onlineFlow
import com.trinityenergie.energycourtage.data.changes
import com.trinityenergie.energycourtage.data.notifications
import com.trinityenergie.energycourtage.model.Route
import com.trinityenergie.energycourtage.model.UserRole
import com.trinityenergie.energycourtage.push.Push
import com.trinityenergie.energycourtage.ui.chat.ChatTab
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.home.HomeScreen
import com.trinityenergie.energycourtage.ui.invoices.InvoiceSheet
import com.trinityenergie.energycourtage.ui.legal.LegalDocumentSheet
import com.trinityenergie.energycourtage.ui.legal.MandateSheet
import com.trinityenergie.energycourtage.ui.legal.outstandingRequiredDocuments
import com.trinityenergie.energycourtage.ui.notifications.NotificationsSheet
import com.trinityenergie.energycourtage.ui.onboarding.OnboardingScreen
import com.trinityenergie.energycourtage.ui.onboarding.contractPdf
import com.trinityenergie.energycourtage.ui.onboarding.needsOnboarding
import com.trinityenergie.energycourtage.ui.profile.ProfileTab
import com.trinityenergie.energycourtage.ui.recommendations.CreateRecommendationSheet
import com.trinityenergie.energycourtage.ui.recommendations.RecommendationsTab
import com.trinityenergie.energycourtage.ui.sms.PhoneVerificationSheet
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.brandGlass
import kotlinx.coroutines.launch

private enum class Tab(val label: String, val icon: ImageVector, val selected: ImageVector) {
    Home("Accueil", Icons.Outlined.Home, Icons.Filled.Home),
    Recommendations("Reco", Icons.Outlined.ViewAgenda, Icons.Filled.ViewAgenda),
    Chat("Chat", Icons.Outlined.ChatBubbleOutline, Icons.Filled.ChatBubble),
    Profile("Profil", Icons.Outlined.PersonOutline, Icons.Filled.Person),
}

/**
 * The four-tab shell (App/RootView.swift). One binary serves both
 * populations: the tabs are the same, and the role decides what appears in
 * them. Over the tabs: the legal gate, then the apporteur's onboarding, and
 * the sheets opened from anywhere -- an invoice, a legal text, notifications.
 */
@Composable
fun RootScreen(
    ready: AppModel.Phase.Ready,
    route: Route?,
    onRouteHandled: () -> Unit,
    onSignOut: () -> Unit,
) {
    val deps = ready.deps
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var tab by rememberSaveable { mutableIntStateOf(0) }
    var homeRefresh by rememberSaveable { mutableIntStateOf(0) }
    var unread by remember { mutableIntStateOf(0) }
    var showsNotifications by remember { mutableStateOf(false) }
    var showsCreate by remember { mutableStateOf(false) }
    var showsMandate by remember { mutableStateOf(false) }
    var showsPhone by remember { mutableStateOf(false) }
    var legalKey by remember { mutableStateOf<String?>(null) }
    var requiredKey by remember { mutableStateOf<String?>(null) }
    var showsOnboarding by remember { mutableStateOf(false) }
    var openedInvoice by remember { mutableStateOf<String?>(null) }
    var openReco by remember { mutableStateOf<String?>(null) }
    var openThread by remember { mutableStateOf<String?>(null) }
    val online by remember { context.onlineFlow() }.collectAsState(initial = true)

    suspend fun refreshBadge() { runCatching { unread = deps.notifications().unreadCount() } }

    /** The next required document not yet accepted -- a first launch, or a
     *  revised CGU -- and once there is none, for an apporteur, onboarding.
     *  Offline, nothing is presented: it would reopen every time it closed. */
    suspend fun presentGates() {
        if (!deps.isDemo) {
            val outstanding = runCatching { deps.outstandingRequiredDocuments() }.getOrNull() ?: return
            requiredKey = outstanding.firstOrNull()
            if (requiredKey != null) return
        }
        if (deps.role == UserRole.Apporteur) {
            showsOnboarding = runCatching { deps.needsOnboarding() }.getOrDefault(false)
        }
    }

    LaunchedEffect(Unit) { presentGates() }
    LaunchedEffect(Unit) { Push.register(context.applicationContext, deps) }
    // re-read on every reconnection as well as at launch
    LaunchedEffect(online) { if (online) refreshBadge() }
    LaunchedEffect(Unit) { deps.changes().collect { refreshBadge() } }

    // A tapped notification -- on the lock screen or in the list -- opens what
    // it is about instead of whatever tab was last showing.
    fun open(r: Route) {
        showsNotifications = false
        when (r) {
            is Route.Invoice -> openedInvoice = r.id
            is Route.Thread -> { openThread = r.id; tab = Tab.Chat.ordinal }
            is Route.Recommendation -> { openReco = r.id; tab = Tab.Recommendations.ordinal }
        }
    }
    LaunchedEffect(route) { route?.let { open(it); onRouteHandled() } }

    // Back from another tab returns to Accueil before it leaves the app
    androidx.activity.compose.BackHandler(enabled = tab != Tab.Home.ordinal) { tab = Tab.Home.ordinal; homeRefresh++ }

    // asked here, once the app is in use: a prompt on the first screen is the
    // one people decline
    if (!deps.isDemo) Push.RequestNotificationPermission()

    Column(Modifier.fillMaxSize().background(Palette.night)) {
        // Said plainly: a request failing with no signal reads as "the app is
        // broken" to someone in a client's basement. Nothing is queued
        // offline, so it must not promise changes will be sent later.
        AnimatedVisibility(!online, enter = expandVertically(), exit = shrinkVertically()) {
            Row(
                Modifier.fillMaxWidth().background(Palette.textSecondary).statusBarsPadding().padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.WifiOff, null, tint = Color.White, modifier = Modifier.padding(end = 6.dp).size(14.dp))
                Text("Hors ligne — vos modifications ne peuvent pas être enregistrées", style = Type.caption, color = Color.White)
            }
        }

        Scaffold(
            modifier = Modifier.weight(1f),
            containerColor = Palette.night,
            // each screen paints its own glow up to the top edge
            contentWindowInsets = WindowInsets(0),
            bottomBar = {
                NavigationBar(containerColor = Palette.night.copy(alpha = 0.96f), tonalElevation = 0.dp) {
                    Tab.entries.forEachIndexed { i, t ->
                        NavigationBarItem(
                            selected = tab == i,
                            onClick = { if (i == 0 && tab != 0) homeRefresh++; tab = i },
                            icon = {
                                BadgedBox(badge = {
                                    if (t == Tab.Home && unread > 0) Badge(containerColor = Palette.destructive) { Text("$unread") }
                                }) { Icon(if (tab == i) t.selected else t.icon, null) }
                            },
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
                        profiles = deps.profiles,
                        refreshKey = homeRefresh,
                        accessory = { Bell(unread) { showsNotifications = true } },
                        onOpenMandate = { showsMandate = true },
                        onNewRecommendation = { showsCreate = true },
                    )
                    Tab.Recommendations -> RecommendationsTab(
                        deps = deps,
                        openRecommendationId = openReco,
                        onRouteConsumed = { openReco = null },
                        onOpenInvoice = { openedInvoice = it },
                    )
                    Tab.Chat -> ChatTab(deps = deps, openThreadId = openThread, onRouteConsumed = { openThread = null })
                    Tab.Profile -> ProfileTab(
                        deps = deps,
                        onSignOut = onSignOut,
                        onOpenLegal = { legalKey = it },
                        onOpenMandate = { showsMandate = true },
                        onVerifyPhone = { showsPhone = true },
                        onOpenContract = { profileId ->
                            scope.launch {
                                val pdf = runCatching { deps.contractPdf(profileId) }.getOrNull()
                                if (pdf != null) Files.open(context, pdf, "Contrat d'apporteur.pdf")
                                else Toast.makeText(context, "Le PDF du contrat est en préparation. Réessayez dans un instant.", Toast.LENGTH_LONG).show()
                            }
                        },
                    )
                }
            }
        }
    }

    // ---------------------------------------------------------------- sheets
    if (showsCreate) CreateRecommendationSheet(
        deps,
        onDismiss = { showsCreate = false },
        onCreated = { tab = Tab.Recommendations.ordinal; homeRefresh++ },
    )
    if (showsNotifications) NotificationsSheet(
        deps,
        onOpen = { open(it) },
        onDismiss = { showsNotifications = false; scope.launch { refreshBadge() } },
    )
    if (showsMandate) MandateSheet(
        deps,
        onDismiss = { showsMandate = false; homeRefresh++ },
        onSigned = { showsMandate = false; homeRefresh++ },
    )
    legalKey?.let { key -> LegalDocumentSheet(deps, key, required = false, onDismiss = { legalKey = null }, onAccepted = { legalKey = null }) }
    if (showsPhone) PhoneVerificationSheet(deps, onDismiss = { showsPhone = false }, onVerified = { showsPhone = false })
    openedInvoice?.let { id -> InvoiceSheet(deps, id, onDismiss = { openedInvoice = null; homeRefresh++ }) }

    // the gates come last so they sit above everything else
    requiredKey?.let { key ->
        LegalDocumentSheet(deps, key, required = true, onDismiss = {}, onAccepted = {
            requiredKey = null
            scope.launch { presentGates() }
        })
    }
    if (showsOnboarding && requiredKey == null) OnboardingScreen(
        deps,
        onFinished = { showsOnboarding = false; homeRefresh++ },
        onSignOut = onSignOut,
    )
}

/** The bell, with its unread count, beside the wordmark. */
@Composable
private fun Bell(unread: Int, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).brandGlass().clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(
            if (unread > 0) Icons.Filled.Notifications else Icons.Outlined.Notifications,
            if (unread > 0) "Notifications, $unread non lues" else "Notifications",
            tint = Palette.brand, modifier = Modifier.size(20.dp),
        )
        if (unread > 0) Box(Modifier.align(Alignment.TopEnd).padding(10.dp).size(8.dp).background(Palette.destructive, CircleShape))
    }
}
