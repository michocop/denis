package com.trinityenergie.energycourtage.ui.profile

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Draw
import androidx.compose.material.icons.outlined.EuroSymbol
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.GppMaybe
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.admin
import com.trinityenergie.energycourtage.data.commissions
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.ui.admin.MembersScreen
import com.trinityenergie.energycourtage.ui.admin.PayablesScreen
import com.trinityenergie.energycourtage.ui.admin.label
import com.trinityenergie.energycourtage.ui.admin.switchColors
import com.trinityenergie.energycourtage.ui.components.Avatar
import com.trinityenergie.energycourtage.ui.components.ConfirmDialog
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.ScreenTitle
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.money.CommissionsScreen
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

private const val EXPORT_FILE = "Mes données Trinity Énergie.json"

/**
 * Profil (Features/Profile/ProfileView.swift). Members, payables and
 * commissions open from here, over the tab. What lives in another area opens
 * through a callback:
 * - [onOpenLegal] with "cgu" or "confidentialite";
 * - [onOpenMandate] for the billing mandate ("mandat_facturation") to read and sign;
 * - [onVerifyPhone] for the mobile verification;
 * - [onOpenContract] with a profile id, for that person's signed contract PDF
 *   (the apporteur's own, or a member's from the admin's list);
 * - [onSignOut] after "Se déconnecter", and after the account is deleted.
 *
 * The profile, SMS status and contract are read again whenever the app's
 * window gets focus back -- after the mandate, the phone verification or a
 * PDF viewer closes -- so a signature shows at once.
 */
@Composable
fun ProfileTab(
    deps: Dependencies,
    onSignOut: () -> Unit,
    onOpenLegal: (key: String) -> Unit,
    onOpenMandate: () -> Unit,
    onVerifyPhone: () -> Unit,
    onOpenContract: (profileId: String) -> Unit,
    opensBilling: Boolean = false,
    onBillingOpened: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val extras = remember(deps) { deps.profileExtras() }

    var profile by remember { mutableStateOf<Profile?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var sms by remember { mutableStateOf<SmsStatus?>(null) }
    var contract by remember { mutableStateOf<ContractSummary?>(null) }
    var exporting by remember { mutableStateOf(false) }
    var exported by remember { mutableStateOf<ByteArray?>(null) }
    var deleting by remember { mutableStateOf(false) }
    var confirmsDeletion by remember { mutableStateOf(false) }
    var sheet by remember { mutableStateOf<ProfileSheet?>(null) }
    // Accueil's ceiling notice leads straight to the SIRET
    LaunchedEffect(opensBilling) { if (opensBilling) { sheet = ProfileSheet.Billing; onBillingOpened() } }

    suspend fun load() {
        try {
            val p = deps.profiles.currentProfile()
            profile = p
            error = null
            if (!p.role.isAdmin) {
                sms = runCatching { extras.smsStatus() }.getOrNull() ?: sms
                contract = runCatching { extras.contract(p) }.getOrNull() ?: contract
            }
        } catch (e: Exception) {
            error = e.message
        }
    }

    LaunchedEffect(deps) { load() }
    val window = LocalWindowInfo.current
    LaunchedEffect(window) {
        snapshotFlow { window.isWindowFocused }.drop(1).filter { it }.collect { load() }
    }

    fun setEmailNotifications(on: Boolean) {
        val current = profile ?: return
        val updated = current.copy(emailNotifications = on)
        profile = updated // the switch follows the finger at once
        scope.launch {
            try {
                profile = deps.profiles.save(updated)
            } catch (e: Exception) {
                error = e.message
                load()
            }
        }
    }

    fun export() {
        exporting = true
        scope.launch {
            try {
                val bytes = deps.profiles.exportMyData().toByteArray(Charsets.UTF_8)
                exported = bytes
                Files.share(context, bytes, EXPORT_FILE, "application/json")
            } catch (e: Exception) {
                error = e.message
            }
            exporting = false
        }
    }

    BrandBackground {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())
                .padding(horizontal = Spacing.gutter).padding(bottom = Spacing.xl),
            verticalArrangement = Arrangement.spacedBy(Spacing.l),
        ) {
            ScreenTitle("Profil")

            val p = profile
            if (p == null && error == null) LoadingBlock()
            if (p != null) {
                Identity(p)
                if (p.role.isAdmin) {
                    ConsoleRow("Apporteurs", Icons.Outlined.Group) { sheet = ProfileSheet.Members }
                    ConsoleRow("À régler", Icons.Outlined.EuroSymbol) { sheet = ProfileSheet.Payables }
                } else {
                    ConsoleRow("Mes gains", Icons.Outlined.EuroSymbol) { sheet = ProfileSheet.Commissions }
                    Billing(p, onEdit = { sheet = ProfileSheet.Billing }, onOpenMandate = onOpenMandate)
                    contract?.let { ContractCard(it) { onOpenContract(p.id) } }
                    sms?.takeIf { it.smsRequired }?.let { MobileCard(it, onVerifyPhone) }
                }
            }

            SecondaryActionButton("Conditions générales", icon = Icons.Outlined.Description) { onOpenLegal("cgu") }
            SecondaryActionButton("Confidentialité", icon = Icons.Outlined.Lock) { onOpenLegal("confidentialite") }

            if (p != null) {
                Row(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Notifications par e-mail", style = Type.body, color = Palette.textPrimary)
                        Text("Factures à signer, paiements, relances.", style = Type.caption, color = Palette.textSecondary)
                    }
                    Switch(p.emailNotifications ?: true, ::setEmailNotifications, colors = switchColors())
                }
            }

            // RGPD: what is held about you, in one file you keep
            val bytes = exported
            if (bytes != null) {
                SecondaryActionButton("Partager le fichier de mes données", icon = Icons.Outlined.Share) {
                    Files.share(context, bytes, EXPORT_FILE, "application/json")
                }
            } else {
                SecondaryActionButton(if (exporting) "Préparation…" else "Exporter mes données", icon = Icons.Outlined.FileDownload,
                    enabled = !exporting, onClick = ::export)
            }

            SecondaryActionButton("Se déconnecter", icon = Icons.AutoMirrored.Outlined.Logout, onClick = onSignOut)

            // an account must be deletable from inside the app
            Row(Modifier.fillMaxWidth().clickable(enabled = !deleting, role = Role.Button) { confirmsDeletion = true }
                .padding(vertical = 14.dp), horizontalArrangement = Arrangement.Center) {
                if (deleting) CircularProgressIndicator(color = Palette.destructive, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                else Text("Supprimer mon compte", style = Type.body, color = Palette.destructive, textAlign = TextAlign.Center)
            }

            error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
        }
    }

    if (confirmsDeletion) {
        ConfirmDialog(
            title = "Supprimer définitivement votre compte ?",
            message = "Vos recommandations et vos factures sont conservées pour des raisons légales, mais votre compte et vos données personnelles seront supprimés.",
            confirm = "Supprimer",
            destructive = true,
            onConfirm = {
                confirmsDeletion = false
                deleting = true
                scope.launch {
                    try {
                        deps.profiles.deleteAccount()
                        onSignOut()
                    } catch (e: Exception) {
                        error = e.message
                    }
                    deleting = false
                }
            },
            onDismiss = { confirmsDeletion = false },
        )
    }

    val close = { sheet = null }
    when (sheet) {
        ProfileSheet.Members -> MembersScreen(remember(deps) { deps.admin() }, onOpenContract, close)
        ProfileSheet.Payables -> PayablesScreen(remember(deps) { deps.admin() }, close)
        ProfileSheet.Commissions -> CommissionsScreen(remember(deps) { deps.commissions() }, profile?.fullName ?: deps.fullName, close)
        ProfileSheet.Billing -> profile?.let { p ->
            BillingDetailsScreen(p, save = { draft ->
                // the switch's default is on; never send it as null
                profile = deps.profiles.save(draft.copy(emailNotifications = draft.emailNotifications ?: true))
            }, onDismiss = close)
        }
        null -> {}
    }
}

private enum class ProfileSheet { Members, Payables, Commissions, Billing }

@Composable
private fun Identity(p: Profile) {
    Row(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.l)) {
        Avatar(p.fullName, 64.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(p.fullName, style = Type.cardTitle, color = Palette.textPrimary)
            Text(p.email, style = Type.secondary, color = Palette.textSecondary)
            p.companyName?.takeIf { it.isNotEmpty() }?.let { Text(it, style = Type.secondary, color = Palette.textSecondary) }
        }
    }
}

@Composable
private fun ConsoleRow(title: String, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().cardSurface().clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = Spacing.l, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Icon(icon, null, tint = Palette.brand, modifier = Modifier.size(22.dp))
        Text(title, style = Type.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.textSecondary)
    }
}

@Composable
private fun Billing(p: Profile, onEdit: () -> Unit, onOpenMandate: () -> Unit) {
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text("Facturation", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)

        Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onEdit), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Coordonnées sur vos factures", style = Type.secondary, color = Palette.textSecondary)
                if (BillingRules.hasBillingAddress(p)) {
                    Text("${p.address}, ${p.postalCode} ${p.city}", style = Type.secondary, color = Palette.textPrimary)
                } else {
                    Text("Adresse à compléter", style = Type.secondary, color = Palette.destructive)
                }
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.textSecondary)
        }

        HorizontalDivider(color = Palette.hairline)

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Régime de TVA", style = Type.secondary, color = Palette.textSecondary, modifier = Modifier.weight(1f))
            Text(if (p.vatLiable) "Assujetti (20 %)" else "Franchise en base (293 B)", style = Type.secondary, color = Palette.textPrimary)
        }

        HorizontalDivider(color = Palette.hairline)

        if (p.canBeInvoiced) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                Icon(Icons.Filled.CheckCircle, null, tint = Palette.success, modifier = Modifier.size(20.dp))
                Text("Mandat de facturation signé", style = Type.secondary, color = Palette.textPrimary)
            }
        } else {
            Text("Le mandat autorise Trinity Énergie à établir vos factures d'apport d'affaires en votre nom. Il doit être signé avant toute facturation.",
                style = Type.secondary, color = Palette.textPrimary)
            // opens the document to read; it is signed there, never from a summary
            PrimaryActionButton("Lire et signer le mandat", onClick = onOpenMandate)
        }
    }
}

/** The signed contract, as filed: opens the PDF the company holds too. */
@Composable
private fun ContractCard(contract: ContractSummary, onOpen: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().cardSurface().clickable(role = Role.Button, onClick = onOpen)
            .semantics { onClick(label = "Ouvre le PDF du contrat") { onOpen(); true } }
            .padding(Spacing.l),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Icon(Icons.Outlined.Draw, null, tint = Palette.success, modifier = Modifier.width(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Contrat d'apporteur signé", style = Type.body, color = Palette.textPrimary)
            Text("${Dates.medium(contract.signedAt)} · ${contract.businessStatus.label} · ${contract.reference}",
                style = Type.caption, color = Palette.textSecondary)
        }
        Icon(Icons.Outlined.Description, null, tint = Palette.brand, modifier = Modifier.size(18.dp))
    }
}

/** The number signatures are confirmed on. Changing the phone in the billing
 *  details takes the verification away, so this is where it is given back. */
@Composable
private fun MobileCard(status: SmsStatus, onVerify: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().cardSurface().clickable(role = Role.Button, onClick = onVerify).padding(Spacing.l),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Icon(if (status.phoneVerified) Icons.Filled.VerifiedUser else Icons.Outlined.GppMaybe, null,
            tint = if (status.phoneVerified) Palette.success else Palette.rewardText, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(if (status.phoneVerified) "Mobile vérifié" else "Vérifier mon mobile", style = Type.body, color = Palette.textPrimary)
            Text(
                if (status.phoneVerified) "${status.maskedPhone.orEmpty()} · reçoit les codes de signature" else "Nécessaire pour signer vos factures",
                style = Type.caption, color = Palette.textSecondary,
            )
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.textSecondary)
    }
}
