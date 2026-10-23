package com.trinityenergie.energycourtage.ui.sms

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Sms
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.sms
import com.trinityenergie.energycourtage.data.smsDemoHint
import com.trinityenergie.energycourtage.model.MobileNumber
import com.trinityenergie.energycourtage.model.SmsChallenge
import com.trinityenergie.energycourtage.model.SmsConfirmation
import com.trinityenergie.energycourtage.model.SmsPurpose
import com.trinityenergie.energycourtage.ui.components.CodeField
import com.trinityenergie.energycourtage.ui.components.CodePhase
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Sora
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal val SmsTitle = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, lineHeight = 32.sp)

/** The wording for an error caught from a call: its message, or a fallback. */
internal fun Throwable.say(): String = message?.takeIf { it.isNotBlank() } ?: "Une erreur est survenue. Réessayez."

/** A message line with its icon, in the destructive colour or the success one. */
@Composable
internal fun MessageLine(text: String, icon: ImageVector = Icons.Filled.ErrorOutline, tint: androidx.compose.ui.graphics.Color = Palette.destructive) {
    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp).padding(top = 2.dp))
        Text(text, style = Type.secondary, color = tint)
    }
}

@Composable
private fun Badge(icon: ImageVector, accepted: Boolean) {
    Box(
        Modifier.size(52.dp).background(if (accepted) Palette.successSoft else Palette.brandSoft, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = if (accepted) Palette.success else Palette.brand, modifier = Modifier.size(24.dp))
    }
}

/**
 * Enters a code sent by SMS: for a signature, or to prove a number (iOS
 * SmsCodeView). The code was sent before this appears; this checks it, and
 * sends another on request once the half-minute the server enforces has passed.
 */
@Composable
fun SmsCodeCard(
    title: String,
    explanation: String,
    maskedPhone: String,
    demoHint: String?,
    resend: suspend () -> SmsChallenge,
    confirm: suspend (String) -> SmsConfirmation,
    onConfirmed: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var masked by remember { mutableStateOf(maskedPhone) }
    var code by remember { mutableStateOf("") }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var phase by remember { mutableStateOf(CodePhase.Entering) }
    var shakes by remember { mutableIntStateOf(0) }
    var resendAt by remember { mutableLongStateOf(System.currentTimeMillis() + 30_000) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var resent by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis(); delay(1_000) } }
    val secondsBeforeResend = ((resendAt - now + 999) / 1000).coerceAtLeast(0)
    val busy = phase == CodePhase.Checking || phase == CodePhase.Accepted

    fun fail(message: String) {
        errorMessage = message
        phase = CodePhase.Wrong
        shakes += 1
        scope.launch {
            delay(500)
            code = ""
            if (phase == CodePhase.Wrong) phase = CodePhase.Entering
        }
    }

    fun check(digits: String) {
        if (digits.length != 6 || busy) return
        phase = CodePhase.Checking
        resent = false
        scope.launch {
            try {
                val answer = confirm(digits)
                if (answer.ok) {
                    errorMessage = null
                    phase = CodePhase.Accepted
                    // long enough to see the boxes turn green, short enough not to wait
                    delay(650)
                    onConfirmed()
                    return@launch
                }
                var message = answer.message ?: "Code incorrect."
                val left = answer.attemptsLeft
                if (answer.reason == "wrong" && left != null) message += if (left == 1) " Dernier essai." else " Encore $left essais."
                if (answer.needsNewCode) resendAt = System.currentTimeMillis()
                fail(message)
            } catch (e: Exception) {
                fail(e.say())
            }
        }
    }

    fun sendAgain() {
        phase = CodePhase.Checking
        scope.launch {
            try {
                val challenge = resend()
                challenge.maskedPhone?.let { masked = it }
                code = ""
                errorMessage = null
                resent = true
                resendAt = System.currentTimeMillis() + 30_000
            } catch (e: Exception) {
                errorMessage = e.say()
            } finally {
                if (phase == CodePhase.Checking) phase = CodePhase.Entering
            }
        }
    }

    Column(
        Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding),
        verticalArrangement = Arrangement.spacedBy(Spacing.xl),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Badge(if (phase == CodePhase.Accepted) Icons.Filled.Check else Icons.Filled.Sms, phase == CodePhase.Accepted)
            Text(if (phase == CodePhase.Accepted) "C'est bon." else title, style = SmsTitle, color = Palette.textPrimary,
                modifier = Modifier.padding(top = 4.dp))
            Text("$explanation Code envoyé au $masked.", style = Type.secondary, color = Palette.textSecondary)
        }

        CodeField(
            code = code,
            onCodeChange = { code = it },
            phase = phase,
            shakes = shakes,
            accessibilityLabel = "Code reçu par SMS, six chiffres",
            enabled = !busy,
            onComplete = { check(it) },
        )

        val err = errorMessage
        when {
            err != null -> MessageLine(err)
            resent -> MessageLine("Nouveau code envoyé.", Icons.AutoMirrored.Filled.Send, Palette.successText)
            demoHint != null -> Text(demoHint, style = Type.secondary, color = Palette.textSecondary)
        }

        PrimaryActionButton(
            if (phase == CodePhase.Checking) "Vérification…" else "Valider",
            enabled = code.length == 6 && !busy,
        ) { check(code) }

        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            TextLink(
                if (secondsBeforeResend > 0) "Renvoyer un code dans $secondsBeforeResend s" else "Renvoyer un code",
                color = if (secondsBeforeResend > 0) Palette.textSecondary else Palette.brand,
                onClick = { if (secondsBeforeResend == 0L && !busy) sendAgain() },
            )
        }
    }
}

/**
 * A number, then the code sent to it (iOS PhoneVerificationView). Used to
 * prove a number from the profile, and inline before a first signature --
 * where the one signing code both proves the number and confirms the
 * signature. To be placed in a scrolling column.
 */
@Composable
fun PhoneThenCode(
    title: String,
    explanation: String,
    codeTitle: String,
    codeExplanation: String,
    initialPhone: String,
    demoHint: String?,
    send: suspend (phone: String, resend: Boolean) -> SmsChallenge,
    confirm: suspend (String) -> SmsConfirmation,
    onConfirmed: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var phone by remember(initialPhone) { mutableStateOf(MobileNumber.formatted(initialPhone)) }
    var sentTo by remember { mutableStateOf<String?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val number = MobileNumber.e164(phone)

    fun sendCode() {
        val n = number ?: return
        working = true
        scope.launch {
            try {
                val challenge = send(n, false)
                errorMessage = null
                if (!challenge.required) onConfirmed()   // a signing window already covers it: no SMS
                else sentTo = challenge.maskedPhone ?: n
            } catch (e: Exception) {
                errorMessage = e.say()
            } finally {
                working = false
            }
        }
    }

    AnimatedContent(
        targetState = sentTo,
        transitionSpec = {
            if (targetState != null) (slideInHorizontally { it } + fadeIn()) togetherWith (slideOutHorizontally { -it } + fadeOut())
            else (slideInHorizontally { -it } + fadeIn()) togetherWith (slideOutHorizontally { it } + fadeOut())
        },
        label = "phone-step",
    ) { to ->
        if (to != null) {
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.xl)) {
                SmsCodeCard(
                    title = codeTitle,
                    explanation = codeExplanation,
                    maskedPhone = to,
                    demoHint = demoHint,
                    resend = { send(MobileNumber.e164(phone) ?: phone, true) },
                    confirm = confirm,
                    onConfirmed = onConfirmed,
                )
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.AutoMirrored.Filled.Undo, null, tint = Palette.textSecondary, modifier = Modifier.size(16.dp))
                        TextLink("Changer de numéro", color = Palette.textSecondary) { sentTo = null }
                    }
                }
            }
        } else {
            Column(
                Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding),
                verticalArrangement = Arrangement.spacedBy(Spacing.l),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Badge(Icons.Filled.PhoneIphone, accepted = false)
                    Text(title, style = SmsTitle, color = Palette.textPrimary, modifier = Modifier.padding(top = 4.dp))
                    Text(explanation, style = Type.secondary, color = Palette.textSecondary)
                }
                Box {
                    LabelledField(
                        label = "Numéro de mobile",
                        value = phone,
                        // what is typed, as typed: rewriting it on every keystroke lost digits
                        onValueChange = { typed -> phone = typed.filter { it.isDigit() || it == ' ' || it == '+' }.take(20) },
                        placeholder = "06 12 34 56 78",
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone, imeAction = ImeAction.Send),
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSend = { if (!working) sendCode() }),
                    )
                    androidx.compose.animation.AnimatedVisibility(number != null, Modifier.align(Alignment.BottomEnd).padding(end = Spacing.l, bottom = 17.dp)) {
                        Icon(Icons.Filled.CheckCircle, "Numéro valide", tint = Palette.success, modifier = Modifier.size(20.dp))
                    }
                }
                val err = errorMessage
                if (err != null) MessageLine(err)
                else if (phone.isNotEmpty() && number == null) {
                    Text("Un numéro de mobile : 06 ou 07, ou international avec son +.", style = Type.caption, color = Palette.textSecondary)
                }
                PrimaryActionButton(if (working) "Envoi…" else "Recevoir un code", enabled = number != null && !working) { sendCode() }
            }
        }
    }
}

/**
 * Proving a mobile number from the profile: the number, then the code sent to
 * it (purpose `verify_phone`). [onVerified] is called once the code is
 * confirmed -- the caller closes the sheet and reloads what shows the number;
 * [onDismiss] when it is cancelled.
 */
@Composable
fun PhoneVerificationSheet(deps: Dependencies, onDismiss: () -> Unit, onVerified: () -> Unit) {
    val repo = remember(deps) { deps.sms() }
    var initialPhone by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(deps) {
        initialPhone = runCatching { deps.profiles.currentProfile().phone }.getOrNull() ?: ""
    }
    FullScreenSheet(title = "Votre mobile", onDismiss = onDismiss) {
        val start = initialPhone
        if (start == null) {
            com.trinityenergie.energycourtage.ui.components.LoadingBlock()
        } else {
            PhoneThenCode(
                title = "Votre mobile",
                explanation = "Vos factures se signent avec un code reçu par SMS sur ce numéro. Il ne sert à rien d'autre.",
                codeTitle = "Saisissez le code",
                codeExplanation = "Il prouve que ce numéro est le vôtre.",
                initialPhone = start,
                demoHint = deps.smsDemoHint,
                send = { phone, resend -> repo.requestCode(SmsPurpose.VerifyPhone, null, phone, resend) },
                confirm = { repo.confirm(SmsPurpose.VerifyPhone, it, null) },
                onConfirmed = onVerified,
            )
        }
    }
}

/**
 * The sheet a signature opens while the apporteur proves their number or
 * types the code: shared by the invoice and the contract. [onCancel] closes
 * it ("Annuler"); [onConfirmed] runs once the code is accepted.
 */
@Composable
internal fun SigningSheet(
    step: com.trinityenergie.energycourtage.model.SigningStep,
    phoneExplanation: String,
    codeTitle: String,
    phoneCodeExplanation: String,
    codeExplanation: String,
    initialPhone: String,
    demoHint: String?,
    dismissible: Boolean,
    send: suspend (phone: String?, resend: Boolean) -> SmsChallenge,
    confirm: suspend (String) -> SmsConfirmation,
    onConfirmed: () -> Unit,
    onCancel: () -> Unit,
) {
    // no title: the card says what is being signed, as on iOS
    FullScreenSheet(title = "", onDismiss = if (dismissible) onCancel else null) {
        when (step) {
            com.trinityenergie.energycourtage.model.SigningStep.EnterPhone -> PhoneThenCode(
                title = "Votre mobile",
                explanation = phoneExplanation,
                codeTitle = codeTitle,
                codeExplanation = phoneCodeExplanation,
                initialPhone = initialPhone,
                demoHint = demoHint,
                send = { phone, resend -> send(phone, resend) },
                confirm = confirm,
                onConfirmed = onConfirmed,
            )
            is com.trinityenergie.energycourtage.model.SigningStep.EnterCode -> SmsCodeCard(
                title = codeTitle,
                explanation = codeExplanation,
                maskedPhone = step.maskedPhone,
                demoHint = demoHint,
                resend = { send(null, true) },
                confirm = confirm,
                onConfirmed = onConfirmed,
            )
        }
        if (dismissible) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                TextLink("Annuler", color = Palette.textSecondary, onClick = onCancel)
            }
        }
    }
}
