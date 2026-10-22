package com.trinityenergie.energycourtage.ui.admin

import androidx.compose.foundation.background
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Draw
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.core.Money
import com.trinityenergie.energycourtage.data.AdminRepository
import com.trinityenergie.energycourtage.model.Invite
import com.trinityenergie.energycourtage.model.MemberOverview
import com.trinityenergie.energycourtage.model.UserRole
import com.trinityenergie.energycourtage.ui.components.Avatar
import com.trinityenergie.energycourtage.ui.components.EmptyState
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.ScreenTitle
import com.trinityenergie.energycourtage.ui.components.SearchField
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.components.SegmentedPicker
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch

/**
 * The admin's members: who is in, who is waiting, who has gone quiet
 * (Features/Admin/MembersView.swift). [onOpenContract] opens a member's
 * signed contract PDF, by profile id.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MembersScreen(repository: AdminRepository, onOpenContract: (profileId: String) -> Unit, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var members by remember { mutableStateOf<List<MemberOverview>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var pendingOnly by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf<String?>(null) }
    var showsInvite by remember { mutableStateOf(false) }

    suspend fun load() {
        try {
            members = repository.members()
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        loaded = true
    }

    fun act(member: MemberOverview, action: suspend () -> Unit) {
        busy = member.id
        scope.launch {
            try { action(); load() } catch (e: Exception) { error = e.message }
            busy = null
        }
    }

    LaunchedEffect(repository) { load() }

    val pending = MemberRules.pendingCount(members)
    LaunchedEffect(pending) { if (pending == 0) pendingOnly = false }
    val visible = MemberRules.visible(members, pendingOnly, query)

    FullScreenSheet("", onDismiss, back = true, scrolls = false) {
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } },
            modifier = Modifier.fillMaxWidth().weight(1f),
        ) {
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                item { ScreenTitle("Apporteurs") }
                item { SearchField("Rechercher un apporteur", query, { query = it }) }
                if (pending > 0) item {
                    Row(
                        Modifier.fillMaxWidth().background(Palette.rewardSoft, RoundedCornerShape(Radius.button))
                            .padding(horizontal = Spacing.l, vertical = Spacing.s),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("$pending en attente de validation", style = Type.secondary, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                        Switch(pendingOnly, { pendingOnly = it }, colors = switchColors())
                    }
                }
                item { PrimaryActionButton("Inviter un apporteur") { showsInvite = true } }
                error?.let { item { Text(it, style = Type.secondary, color = Palette.destructive) } }
                when {
                    !loaded -> item { LoadingBlock() }
                    visible.isEmpty() -> item { EmptyState(Icons.Outlined.Group, "Aucun apporteur") }
                    else -> items(visible, key = { it.id }) { member ->
                        MemberRow(
                            member,
                            busy = busy == member.id,
                            onApprove = { act(member) { repository.approve(member.id) } },
                            onSuspend = { act(member) { repository.setStatus(member.id, "suspended") } },
                            onReactivate = { act(member) { repository.setStatus(member.id, "active") } },
                            onSetBankDetails = { onFile -> act(member) { repository.setBankDetailsOnFile(member.id, onFile, null) } },
                            onOpenContract = { onOpenContract(member.id) },
                        )
                    }
                }
                item { Spacer(Modifier.size(Spacing.l)) }
            }
        }
    }

    if (showsInvite) InviteSheet(repository, onDismiss = { showsInvite = false; scope.launch { load() } })
}

@Composable
internal fun switchColors() = SwitchDefaults.colors(
    checkedThumbColor = Color.White, checkedTrackColor = Palette.brandFill, checkedBorderColor = Palette.brandFill,
    uncheckedThumbColor = Palette.textSecondary, uncheckedTrackColor = Palette.track, uncheckedBorderColor = Palette.hairline,
)

@Composable
private fun MemberRow(
    member: MemberOverview,
    busy: Boolean,
    onApprove: () -> Unit,
    onSuspend: () -> Unit,
    onReactivate: () -> Unit,
    onSetBankDetails: (Boolean) -> Unit,
    onOpenContract: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().cardSurface().padding(Spacing.l).alpha(if (busy) 0.6f else 1f),
        verticalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Avatar(member.fullName, 48.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(member.fullName, style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                Text(member.email, style = Type.secondary, color = Palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            StatusPill(member.status)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.l)) {
            Metric("Actives", "${member.activeRecommendations}")
            Metric("Dû", Money.euros(member.owedTotal))
            Metric("Versé", Money.euros(member.paidTotal))
        }

        if (member.role == UserRole.Apporteur) {
            val signedAt = member.contractSignedAt
            if (signedAt != null) {
                Row(
                    Modifier.fillMaxWidth().clickable(enabled = !busy, onClick = onOpenContract),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.Outlined.Draw, null, tint = Palette.successText, modifier = Modifier.size(14.dp))
                    Text("Contrat signé le ${Dates.medium(signedAt)}" + (member.businessStatus?.let { " · ${it.label}" } ?: ""),
                        style = Type.caption, color = Palette.successText, modifier = Modifier.weight(1f))
                    Icon(Icons.Outlined.Description, null, tint = Palette.brand, modifier = Modifier.size(14.dp))
                    Text("PDF", style = Type.caption.copy(fontWeight = FontWeight.SemiBold), color = Palette.brand)
                }
            } else Flag("Contrat d'apporteur pas encore signé", Palette.textSecondary)
        }

        // two things that quietly block payment, said before anyone wonders
        if (!member.hasMandate) Flag("Mandat de facturation non signé", Palette.rewardText)
        if (member.hasNeverRecommended && member.isActive) Flag("Aucune recommandation envoyée", Palette.textSecondary)
        if (!member.bankDetailsOnFile) Flag("Coordonnées bancaires non renseignées", Palette.rewardText)

        Row(verticalAlignment = Alignment.CenterVertically) {
            if (member.isPending) {
                Text("Valider", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.brand,
                    modifier = Modifier.clickable(enabled = !busy, onClick = onApprove).padding(vertical = Spacing.xs))
            }
            Spacer(Modifier.weight(1f))
            Box {
                IconButton(onClick = { menu = true }, enabled = !busy,
                    modifier = Modifier.semantics { contentDescription = "Actions pour ${member.fullName}" }) {
                    Icon(Icons.Outlined.MoreHoriz, null, tint = Palette.textSecondary)
                }
                DropdownMenu(menu, { menu = false }, containerColor = Palette.surface) {
                    if (member.isActive) {
                        DropdownMenuItem({ Text("Suspendre", style = Type.body, color = Palette.destructive) }, { menu = false; onSuspend() })
                    } else {
                        DropdownMenuItem({ Text("Réactiver", style = Type.body, color = Palette.textPrimary) }, { menu = false; onReactivate() })
                    }
                    HorizontalDivider(color = Palette.hairline)
                    if (member.bankDetailsOnFile) {
                        DropdownMenuItem({ Text("Coordonnées bancaires manquantes", style = Type.body, color = Palette.textPrimary) },
                            { menu = false; onSetBankDetails(false) })
                    } else {
                        DropdownMenuItem({ Text("Coordonnées bancaires enregistrées", style = Type.body, color = Palette.textPrimary) },
                            { menu = false; onSetBankDetails(true) })
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusPill(status: String) {
    val (text, bg, fg) = when (status) {
        "active" -> Triple("Actif", Palette.successSoft, Palette.successText)
        "pending" -> Triple("En attente", Palette.rewardSoft, Palette.rewardText)
        else -> Triple("Suspendu", Palette.track, Palette.textSecondary)
    }
    Text(text, style = Type.badge, color = fg,
        modifier = Modifier.background(bg, RoundedCornerShape(Radius.button)).padding(horizontal = 12.dp, vertical = 5.dp))
}

@Composable
private fun Metric(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(value, style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
        Text(label, style = Type.caption, color = Palette.textSecondary)
    }
}

@Composable
private fun Flag(text: String, tint: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Outlined.ErrorOutline, null, tint = tint, modifier = Modifier.size(14.dp))
        Text(text, style = Type.caption, color = tint)
    }
}

/**
 * Creating an invitation (send-invite). Sign-in is by a code emailed to that
 * address, so what the person needs next is the app itself: the link, sent
 * however reaches them.
 */
@Composable
private fun InviteSheet(repository: AdminRepository, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }
    var role by remember { mutableStateOf(UserRole.Apporteur) }
    var autoActivate by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var lastInvite by remember { mutableStateOf<Invite?>(null) }

    FullScreenSheet("Inviter", onDismiss) {
        lastInvite?.let { invite ->
            Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Icon(Icons.Filled.CheckCircle, null, tint = Palette.success, modifier = Modifier.size(20.dp))
                    Text("Invitation envoyée à ${invite.email}", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.success)
                }
                Text("Envoyez-lui aussi le lien de l'application par SMS ou WhatsApp, au cas où l'e-mail arriverait dans ses indésirables.",
                    style = Type.secondary, color = Palette.textSecondary)
                SecondaryActionButton("Envoyer le lien de l'application", icon = Icons.Outlined.Share) {
                    Files.shareText(context, InviteText.installMessage(invite.email), "Envoyer le lien de l'application")
                }
            }
        }

        LabelledField("Adresse e-mail", email, { email = it }, placeholder = "apporteur@exemple.fr",
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false))

        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Text("Rôle", style = Type.caption, color = Palette.textSecondary, modifier = Modifier.padding(start = 4.dp))
            SegmentedPicker(role, listOf(UserRole.Apporteur to "Apporteur", UserRole.Admin to "Administrateur"), { role = it })
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Activer automatiquement", style = Type.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Switch(autoActivate, { autoActivate = it }, colors = switchColors())
        }
        Text(
            if (autoActivate) "La personne reçoit un e-mail, ouvre l'application avec son adresse et se connecte avec le code reçu : aucun mot de passe."
            else "La personne reçoit un e-mail ; un administrateur devra ensuite valider son inscription.",
            style = Type.secondary, color = Palette.textSecondary,
        )

        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }

        PrimaryActionButton(
            if (working) "Envoi…" else "Envoyer l'invitation",
            enabled = InviteText.isValidEmail(email),
            working = working,
        ) {
            working = true
            scope.launch {
                try {
                    lastInvite = repository.createInvite(email.trim(), role, autoActivate)
                    error = null
                } catch (e: Exception) {
                    error = e.message
                }
                working = false
            }
        }
    }
}
