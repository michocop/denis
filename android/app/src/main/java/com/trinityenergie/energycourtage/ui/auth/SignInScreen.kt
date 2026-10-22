package com.trinityenergie.energycourtage.ui.auth

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.core.EmailCodeException
import com.trinityenergie.energycourtage.ui.components.CodeField
import com.trinityenergie.energycourtage.ui.components.CodePhase
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.BrandGradient
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.TrinityWordmark
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The site's headline: a white line, then a line in the blue gradient. */
@Composable
fun BrandHeadline(first: String, second: String, size: Int = 34) {
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = Palette.textPrimary)) { append(first); append("\n") }
            withStyle(SpanStyle(brush = BrandGradient)) { append(second) }
        },
        style = Type.screenTitle.copy(fontSize = size.sp, lineHeight = (size + 6).sp),
    )
}

@Composable
fun ErrorLine(message: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.Top) {
        Icon(Icons.Filled.Error, null, tint = Palette.destructive, modifier = Modifier.size(18.dp).padding(top = 2.dp))
        Text(message, style = Type.secondary, color = Palette.destructive)
    }
}

/**
 * Sign in by emailed code, no password (App/RootView.swift's SignInView):
 * the address, then six digits. Auth refuses a second email within a minute,
 * so "Renvoyer" counts down from 60 s.
 */
@Composable
fun SignInScreen(
    notice: String?,
    sendCode: suspend (String) -> Unit,
    verifyCode: suspend (code: String, email: String) -> Unit,
    onDemo: ((asAdmin: Boolean) -> Unit)?,
) {
    var email by rememberSaveable { mutableStateOf("") }
    var codeFor by rememberSaveable { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf("") }
    var phase by remember { mutableStateOf(CodePhase.Entering) }
    var shakes by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf(notice) }
    var resent by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var resendAt by remember { mutableLongStateOf(0L) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var emailFocused by remember { mutableStateOf(false) }
    var choosesDemo by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis(); delay(1000) } }

    val trimmed = email.trim()
    val validEmail = trimmed.contains("@") && trimmed.substringAfter("@").contains(".") && !trimmed.contains(" ")
    val secondsBeforeResend = ((resendAt - now + 999) / 1000).coerceAtLeast(0)
    val typing = emailFocused || codeFor != null

    fun send(again: Boolean = false) {
        if (!validEmail || sending) return
        val address = trimmed.lowercase()
        scope.launch {
            sending = true
            try {
                sendCode(address)
                error = null; code = ""; phase = CodePhase.Entering; resent = again
                resendAt = System.currentTimeMillis() + 60_000
                codeFor = address
            } catch (e: EmailCodeException) {
                // a code is already on its way: go and type it
                if (e.kind == EmailCodeException.Kind.TooSoon && !again) { error = null; codeFor = address }
                else error = e.message
            } catch (e: Exception) {
                error = e.message
            } finally { sending = false }
        }
    }

    fun verify(digits: String, address: String) {
        if (digits.length != 6 || phase != CodePhase.Entering) return
        scope.launch {
            phase = CodePhase.Checking; resent = false
            try {
                verifyCode(digits, address)
                error = null; phase = CodePhase.Accepted
            } catch (e: Exception) {
                error = e.message; phase = CodePhase.Wrong; shakes++
                delay(500)
                code = ""
                if (phase == CodePhase.Wrong) phase = CodePhase.Entering
            }
        }
    }

    BrandBackground {
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().imePadding()
                .padding(horizontal = Spacing.gutter).padding(bottom = Spacing.m)
        ) {
            Spacer(Modifier.height(Spacing.l))
            TrinityWordmark()
            Spacer(Modifier.weight(1f))
            BrandHeadline("Votre espace", "apporteur d'affaires.")
            AnimatedVisibility(!typing, enter = fadeIn(), exit = fadeOut()) {
                Text(
                    "Suivez vos recommandations, signez vos factures et recevez vos commissions.",
                    style = Type.body, color = Palette.textSecondary, modifier = Modifier.padding(top = Spacing.m),
                )
            }
            Spacer(Modifier.weight(1f))

            AnimatedContent(
                targetState = codeFor,
                transitionSpec = {
                    (slideInHorizontally { it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { -it / 3 } + fadeOut())
                },
                label = "step",
            ) { address ->
                Column(
                    Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding),
                    verticalArrangement = Arrangement.spacedBy(Spacing.l),
                ) {
                    if (address == null) {
                        LabelledField(
                            label = "Email", value = email, onValueChange = { email = it },
                            placeholder = "adresse@exemple.fr",
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Send, autoCorrectEnabled = false),
                            keyboardActions = KeyboardActions(onSend = { send() }),
                            modifier = Modifier.onFocusChanged { emailFocused = it.isFocused },
                        )
                        Message(error, resent)
                        PrimaryActionButton(if (sending) "Envoi…" else "Recevoir mon code", enabled = validEmail && !sending) { send() }
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(if (phase == CodePhase.Accepted) "C'est bon." else "Saisissez votre code", style = Type.cardTitle, color = Palette.textPrimary)
                            Text("Six chiffres, envoyés à $address.", style = Type.secondary, color = Palette.textSecondary, maxLines = 2)
                        }
                        CodeField(
                            code = code, onCodeChange = { code = it }, phase = phase, shakes = shakes,
                            accessibilityLabel = "Code reçu par e-mail, six chiffres",
                            enabled = phase != CodePhase.Checking && phase != CodePhase.Accepted,
                        ) { verify(it, address) }
                        Message(error, resent)
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            TextLink("Changer d'adresse", color = Palette.textSecondary) {
                                codeFor = null; code = ""; error = null; resent = false; phase = CodePhase.Entering
                            }
                            Spacer(Modifier.weight(1f))
                            if (secondsBeforeResend > 0) {
                                Text("Renvoyer dans $secondsBeforeResend s", style = Type.label, color = Palette.textSecondary, modifier = Modifier.padding(Spacing.s))
                            } else {
                                TextLink("Renvoyer le code") { send(again = true) }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(Spacing.m))
            AnimatedVisibility(!typing, enter = fadeIn(), exit = fadeOut()) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Text("L'accès est réservé aux apporteurs invités par Trinity Énergie.",
                        style = Type.caption, color = Palette.textSecondary, textAlign = TextAlign.Center)
                    if (onDemo != null) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.AutoAwesome, null, tint = Palette.brand, modifier = Modifier.size(16.dp))
                            TextLink("Découvrir l'application (démo)") { choosesDemo = true }
                        }
                    }
                }
            }
        }
    }

    if (choosesDemo && onDemo != null) {
        AlertDialog(
            onDismissRequest = { choosesDemo = false },
            title = { Text("Découvrir avec des données de démonstration", style = Type.cardTitle) },
            text = { Text("Aucune donnée réelle : les noms, montants et documents sont fictifs.", style = Type.secondary) },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton({ choosesDemo = false; onDemo(false) }) { Text("Vue apporteur", color = Palette.brand) }
                    TextButton({ choosesDemo = false; onDemo(true) }) { Text("Vue entreprise", color = Palette.brand) }
                    TextButton({ choosesDemo = false }) { Text("Annuler", color = Palette.textSecondary) }
                }
            },
            containerColor = Palette.surface,
            titleContentColor = Palette.textPrimary,
            textContentColor = Palette.textSecondary,
        )
    }
}

@Composable
private fun Message(error: String?, resent: Boolean) {
    when {
        error != null -> ErrorLine(error)
        resent -> Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Send, null, tint = Palette.successText, modifier = Modifier.size(16.dp))
            Text("Nouveau code envoyé.", style = Type.secondary, color = Palette.successText)
        }
    }
}

