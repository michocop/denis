package com.trinityenergie.energycourtage.ui.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.TrinityWordmark
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch

/** A centred icon, a title, a line of explanation and what can be done. */
@Composable
private fun StatusScreen(icon: ImageVector, iconTint: androidx.compose.ui.graphics.Color, title: String,
                         body: String?, actions: @Composable () -> Unit) {
    BrandBackground {
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().padding(Spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Spacing.l, Alignment.CenterVertically),
        ) {
            Icon(icon, null, tint = iconTint, modifier = Modifier.size(48.dp))
            Text(title, style = Type.cardTitle, color = Palette.textPrimary, textAlign = TextAlign.Center)
            if (body != null) Text(body, style = Type.body, color = Palette.textSecondary, textAlign = TextAlign.Center)
            actions()
        }
    }
}

@Composable
fun PendingApprovalScreen(email: String, onRefresh: () -> Unit, onSignOut: () -> Unit) = StatusScreen(
    Icons.Outlined.HourglassEmpty, Palette.brand, "Compte en attente de validation",
    "Votre inscription avec $email a bien été enregistrée. Un membre de l'équipe doit la valider avant que vous puissiez accéder à vos recommandations.",
) {
    PrimaryActionButton("Vérifier à nouveau", onClick = onRefresh)
    TextLink("Se déconnecter", color = Palette.textSecondary, onClick = onSignOut)
}

/** Suspended, or an account whose personal data was erased on deletion. */
@Composable
fun SuspendedScreen(onSignOut: () -> Unit) = StatusScreen(
    Icons.Outlined.Lock, Palette.textSecondary, "Accès suspendu",
    "Cet accès n'est plus actif. Contactez votre interlocuteur si vous pensez qu'il s'agit d'une erreur.",
) { TextLink("Se déconnecter", onClick = onSignOut) }

/** A restored session waiting for the fingerprint, the face or the code. */
@Composable
fun LockedScreen(unlock: () -> Unit) {
    LaunchedEffect(Unit) { unlock() }
    StatusScreen(Icons.Outlined.Fingerprint, Palette.brand, "Espace verrouillé", null) {
        PrimaryActionButton("Déverrouiller", modifier = Modifier.widthIn(max = 260.dp), onClick = unlock)
    }
}

/** The first sign-in of an invited address: the person says who they are; the
 *  invitation sent to that address gives the role. No password to choose. */
@Composable
fun CompleteInviteScreen(email: String, onSignOut: () -> Unit, complete: suspend (String, String) -> Unit) {
    var first by rememberSaveable { mutableStateOf("") }
    var last by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val valid = first.isNotBlank() && last.isNotBlank()

    fun submit() {
        if (!valid || working) return
        scope.launch {
            working = true
            try { complete(first.trim(), last.trim()) } catch (e: Exception) { error = e.message } finally { working = false }
        }
    }

    BrandBackground {
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(horizontal = Spacing.gutter)) {
            Row(Modifier.fillMaxWidth().padding(top = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
                TrinityWordmark()
                Spacer(Modifier.weight(1f))
                TextLink("Se déconnecter", color = Palette.textSecondary, onClick = onSignOut)
            }
            Spacer(Modifier.weight(1f))
            BrandHeadline("Bienvenue chez", "Trinity Énergie.", size = 32)
            Text("Votre accès pour $email est ouvert. Dites-nous simplement comment vous appeler.",
                style = Type.body, color = Palette.textSecondary, modifier = Modifier.padding(top = Spacing.m))
            Spacer(Modifier.weight(1f))
            Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                LabelledField("Prénom", first, { first = it }, placeholder = "Prénom",
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next))
                LabelledField("Nom", last, { last = it }, placeholder = "Nom",
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submit() }))
                error?.let { ErrorLine(it) }
                PrimaryActionButton(if (working) "Un instant…" else "Rejoindre Trinity Énergie", enabled = valid && !working) { submit() }
            }
            Spacer(Modifier.height(Spacing.m))
        }
    }
}
