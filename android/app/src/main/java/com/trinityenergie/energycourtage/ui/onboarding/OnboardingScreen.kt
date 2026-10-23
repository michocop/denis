package com.trinityenergie.energycourtage.ui.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.outlined.AccountBox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.contracts
import com.trinityenergie.energycourtage.data.legal
import com.trinityenergie.energycourtage.data.sms
import com.trinityenergie.energycourtage.data.smsDemoHint
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.explanation
import com.trinityenergie.energycourtage.model.label
import com.trinityenergie.energycourtage.model.Particulier
import com.trinityenergie.energycourtage.model.legalForms
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.legal.LegalTextView
import com.trinityenergie.energycourtage.ui.legal.rememberReadToEnd
import com.trinityenergie.energycourtage.ui.sms.MessageLine
import com.trinityenergie.energycourtage.ui.sms.SigningSheet
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.BrandGradient
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Sora
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private val display30 = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 30.sp, lineHeight = 36.sp)
private val signedAtFormat = DateTimeFormatter.ofPattern("d MMMM yyyy 'à' HH:mm", Locale.FRANCE)

/**
 * The apporteur's onboarding (iOS OnboardingView), full screen, before
 * anything else in the app: status, details, then the contract and its annex
 * signed by SMS. Shown when `deps.needsOnboarding()`.
 *
 * [onFinished]: "Accéder à mon espace" after the signature -- dismiss it and
 * refresh Home (the mandate notice goes with the signature).
 * [onSignOut]: "Se déconnecter" from its menu.
 */
@Composable
fun OnboardingScreen(deps: Dependencies, onFinished: () -> Unit, onSignOut: () -> Unit) {
    val model = remember(deps) {
        OnboardingModel(deps.profiles, deps.legal(), deps.sms(), deps.contracts(), isDemo = deps.isDemo)
    }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    LaunchedEffect(model) { model.load() }
    LaunchedEffect(model.advances) { if (model.advances > 0) haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove) }
    LaunchedEffect(model.signatures) { if (model.signatures > 0) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }

    // nothing in the app is reachable before it is done: back goes a step back, never out
    BackHandler { if (!model.isWorking && model.step != OnboardingModel.Step.Status) model.back() }

    BrandBackground {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
            if (model.step != OnboardingModel.Step.Done) TopBar(model, onSignOut)
            AnimatedContent(
                targetState = model.step,
                transitionSpec = {
                    if (targetState.ordinal > initialState.ordinal)
                        (slideInHorizontally(tween(400)) { it } + fadeIn()) togetherWith (slideOutHorizontally(tween(400)) { -it } + fadeOut())
                    else (slideInHorizontally(tween(400)) { -it } + fadeIn()) togetherWith (slideOutHorizontally(tween(400)) { it } + fadeOut())
                },
                modifier = Modifier.fillMaxWidth().weight(1f),
                label = "onboarding-step",
            ) { step ->
                Column(Modifier.fillMaxSize()) {
                    when (step) {
                        OnboardingModel.Step.Status -> StatusStep(model)
                        OnboardingModel.Step.Details -> DetailsStep(model)
                        OnboardingModel.Step.Contract -> ContractStep(model)
                        OnboardingModel.Step.Done -> DoneStep(model, onFinished)
                    }
                }
            }
        }
    }

    model.signingStep?.let { step ->
        SigningSheet(
            step = step,
            phoneExplanation = "Votre signature se confirme avec un code reçu par SMS. Ce même code valide votre numéro.",
            codeTitle = "Signer le contrat",
            phoneCodeExplanation = "Ce code confirme votre signature du contrat et de son annexe.",
            codeExplanation = "Ce code confirme que c'est bien vous qui signez votre contrat d'apporteur d'affaires.",
            initialPhone = model.draft?.phone ?: "",
            demoHint = deps.smsDemoHint,
            dismissible = true,
            send = { phone, resend -> model.requestCode(phone, resend) },
            confirm = { model.confirmCode(it) },
            onConfirmed = { scope.launch { model.codeConfirmed() } },
            onCancel = { model.signingStep = null },
        )
    }
}

/** Back, the three steps as segments, and a way out. */
@Composable
private fun TopBar(model: OnboardingModel, onSignOut: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.gutter - 14.dp, vertical = Spacing.s),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        val first = model.step == OnboardingModel.Step.Status
        IconButton(onClick = { model.back() }, enabled = !first && !model.isWorking, modifier = Modifier.alpha(if (first) 0f else 1f)) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Étape précédente", tint = Palette.textSecondary)
        }
        Row(Modifier.weight(1f).semantics { contentDescription = "Étape ${model.step.ordinal + 1} sur 3" },
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(OnboardingModel.Step.Status, OnboardingModel.Step.Details, OnboardingModel.Step.Contract).forEach { s ->
                val color by animateColorAsState(if (s.ordinal <= model.step.ordinal) Palette.brand else Palette.track, tween(500), label = "segment")
                Box(Modifier.weight(1f).height(4.dp).background(color, RoundedCornerShape(2.dp)))
            }
        }
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreHoriz, "Options", tint = Palette.textSecondary) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, containerColor = Palette.surface) {
                DropdownMenuItem(text = { Text("Se déconnecter", style = Type.label, color = Palette.destructive) },
                    onClick = { menu = false; onSignOut() })
            }
        }
    }
}

// ---------------------------------------------------------------- 1. status

@Composable
private fun ColumnScope.StatusStep(model: OnboardingModel) {
    Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Spacing.gutter)) {
        Text(if (model.firstName.isEmpty()) "Bienvenue." else "Bienvenue, ${model.firstName}.", style = display30, color = Palette.textPrimary,
            modifier = Modifier.padding(top = Spacing.xl))
        Text("Comment exercez-vous ?", style = display30.copy(brush = BrandGradient))
        Text("Votre statut figure sur votre contrat et sur chacune de vos factures.", style = Type.body, color = Palette.textSecondary,
            modifier = Modifier.padding(top = Spacing.m))
        Spacer(Modifier.height(Spacing.xl))
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            BusinessStatus.entries.forEach { status ->
                StatusCard(status, model.status == status) { model.choose(status) }
            }
        }
        Spacer(Modifier.height(Spacing.l))
    }
    PrimaryActionButton("Continuer", enabled = model.status != null,
        modifier = Modifier.padding(horizontal = Spacing.gutter, vertical = Spacing.m)) { model.next() }
}

@Composable
private fun StatusCard(status: BusinessStatus, selected: Boolean, onClick: () -> Unit) {
    val icon: ImageVector = if (status == BusinessStatus.Societe) Icons.Filled.Business else Icons.Outlined.AccountBox
    val scale by animateFloatAsState(if (selected) 1f else 0.985f, spring(dampingRatio = Spring.DampingRatioMediumBouncy), label = "card")
    val shape = RoundedCornerShape(Radius.card)
    Row(
        Modifier.fillMaxWidth().scale(scale).cardSurface()
            .border(1.5.dp, if (selected) Palette.brand else Color.Transparent, shape)
            .clickable(onClick = onClick).padding(Spacing.l)
            .semantics { contentDescription = status.label + if (selected) ", sélectionné" else "" },
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Box(Modifier.size(44.dp).background(if (selected) Palette.brandSoft else Palette.grouped, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = if (selected) Palette.brand else Palette.textSecondary, modifier = Modifier.size(22.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(status.label, style = Type.cardTitle, color = Palette.textPrimary)
            Text(status.explanation, style = Type.secondary, color = Palette.textSecondary)
        }
        Icon(if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null,
            tint = if (selected) Palette.brand else Palette.hairline, modifier = Modifier.size(22.dp))
    }
}

// --------------------------------------------------------------- 2. details

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ColumnScope.DetailsStep(model: OnboardingModel) {
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    LaunchedEffect(Unit) { model.preselectLegalForm() }
    val d = model.draft
    val societe = model.status == BusinessStatus.Societe

    Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Spacing.gutter),
        verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        Column(Modifier.padding(top = Spacing.l), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(if (societe) "Votre activité" else "Vos coordonnées", style = Type.screenTitle, color = Palette.textPrimary)
            Text("Ces informations figurent sur votre contrat et vos factures.", style = Type.secondary, color = Palette.textSecondary)
        }
        if (d == null) {
            val err = model.errorMessage
            if (err != null) {
                MessageLine(err)
                SecondaryActionButton("Réessayer", icon = Icons.Filled.Refresh) { scope.launch { model.load() } }
            } else LoadingBlock()
        } else {
            Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                if (societe) Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Text("Forme juridique", style = Type.caption, color = Palette.textSecondary,
                        modifier = Modifier.padding(start = 4.dp))
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        (model.status?.legalForms ?: emptyList()).forEach { option ->
                            val selected = option == d.legalForm
                            Text(option, style = Type.label, color = if (selected) Palette.textPrimary else Palette.textSecondary,
                                modifier = Modifier
                                    .background(if (selected) Palette.brandSoft else Palette.grouped, RoundedCornerShape(50))
                                    .border(1.dp, if (selected) Palette.brand else Color.Transparent, RoundedCornerShape(50))
                                    .clickable { model.draft = d.copy(legalForm = option) }
                                    .padding(horizontal = 14.dp, vertical = 9.dp))
                        }
                    }
                }
                if (societe) {
                    LabelledField(if (model.companyNameOptional) "Nom commercial (facultatif)" else "Raison sociale",
                        d.companyName ?: "", { model.draft = d.copy(companyName = it) },
                        placeholder = "Lefeuvre Conseil",
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next))
                    LabelledField("SIRET", d.siret ?: "", { v -> model.draft = d.copy(siret = v.filter { it.isDigit() || it == ' ' }.let { t -> var n = 0; t.takeWhile { c -> if (c.isDigit()) n++; n <= 14 } }) },
                        placeholder = "14 chiffres", keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next))
                }
                LabelledField("Adresse", d.address ?: "", { model.draft = d.copy(address = it) }, placeholder = "Numéro et rue",
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, autoCorrectEnabled = false, imeAction = ImeAction.Next))
                Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    LabelledField("Code postal", d.postalCode ?: "", { v -> model.draft = d.copy(postalCode = v.filter(Char::isDigit).take(5)) },
                        placeholder = "59000", modifier = Modifier.width(130.dp),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next))
                    LabelledField("Ville", d.city ?: "", { model.draft = d.copy(city = it) }, placeholder = "Lille",
                        modifier = Modifier.weight(1f),
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { focus.clearFocus() }))
                }
            }
            if (!societe) ParticulierNotice()
        }
        Spacer(Modifier.height(Spacing.s))
    }

    Column(Modifier.fillMaxWidth().padding(horizontal = Spacing.gutter, vertical = Spacing.m),
        verticalArrangement = Arrangement.spacedBy(Spacing.s), horizontalAlignment = Alignment.CenterHorizontally) {
        if (d != null) model.errorMessage?.let { MessageLine(it) }
        val problem = model.detailsProblem
        PrimaryActionButton(if (model.isWorking) "Enregistrement…" else "Continuer", enabled = problem == null && !model.isWorking) {
            focus.clearFocus()
            scope.launch { model.saveDetails() }
        }
        if (problem != null && d != null) Text(problem, style = Type.caption, color = Palette.textSecondary)
    }
}

// -------------------------------------------------------------- 3. contract

/** "123 456 789 00011": a SIRET read back in its groups. */
internal fun groupedSiret(siret: String): String {
    val d = siret.filter(Char::isDigit)
    if (d.length != 14) return siret
    return "${d.substring(0, 3)} ${d.substring(3, 6)} ${d.substring(6, 9)} ${d.substring(9)}"
}

@Composable
private fun ColumnScope.ContractStep(model: OnboardingModel) {
    val scope = rememberCoroutineScope()
    val contract = model.contract
    val mandate = model.mandate
    if (contract != null && mandate != null) {
        val scroll = rememberScrollState()
        val reached = rememberReadToEnd(scroll)
        LaunchedEffect(reached) { if (reached) model.hasReadToEnd = true }
        Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(scroll).padding(horizontal = Spacing.gutter),
            verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
            Column(Modifier.padding(top = Spacing.l), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Votre contrat", style = Type.screenTitle, color = Palette.textPrimary)
                Text("Lisez-le jusqu'au bout : le mandat de facturation, en annexe, permet à Trinity Énergie d'établir vos factures pour vous.",
                    style = Type.secondary, color = Palette.textSecondary)
            }
            Summary(model)
            SelectionContainer {
                Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                    Text(contract.title, style = Type.cardTitle, color = Palette.textPrimary)
                    LegalTextView(contract.body)
                    HorizontalDivider(color = Palette.hairline)
                    Text("Annexe — ${mandate.title}", style = Type.cardTitle, color = Palette.textPrimary)
                    LegalTextView(mandate.body)
                    Text("Contrat version ${contract.version} · mandat version ${mandate.version}", style = Type.caption, color = Palette.textSecondary)
                }
            }
            Spacer(Modifier.height(Spacing.s))
        }
        HorizontalDivider(color = Palette.hairline)
        Column(Modifier.fillMaxWidth().background(Palette.surface.copy(alpha = 0.92f)).padding(Spacing.gutter),
            verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            model.errorMessage?.let { MessageLine(it) }
            Row(
                Modifier.fillMaxWidth().alpha(if (model.hasReadToEnd) 1f else 0.6f)
                    .clickable(enabled = model.hasReadToEnd) { model.agrees = !model.agrees },
                horizontalArrangement = Arrangement.spacedBy(Spacing.m),
            ) {
                Icon(if (model.agrees) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank, null,
                    tint = if (model.agrees) Palette.brand else Palette.textSecondary, modifier = Modifier.size(22.dp))
                Text(
                    if (model.hasReadToEnd) "J'ai lu et j'accepte le contrat d'apporteur d'affaires et le mandat de facturation annexé."
                    else "Faites défiler le contrat jusqu'à la fin pour pouvoir l'accepter.",
                    style = Type.secondary, color = Palette.textPrimary,
                )
            }
            PrimaryActionButton(if (model.isWorking) "Un instant…" else "Signer par SMS", enabled = model.agrees && !model.isWorking) {
                scope.launch { model.startSigning() }
            }
        }
    } else if (model.errorMessage != null) {
        Column(Modifier.fillMaxWidth().weight(1f).padding(Spacing.gutter), verticalArrangement = Arrangement.spacedBy(Spacing.l, Alignment.CenterVertically)) {
            Text(model.errorMessage ?: "", style = Type.secondary, color = Palette.destructive)
            SecondaryActionButton("Réessayer", icon = Icons.Filled.Refresh) { scope.launch { model.load() } }
        }
    } else {
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) { LoadingBlock() }
    }
}

/** What the particulier signs up to, said before the contract says it. */
@Composable
private fun ParticulierNotice() {
    Row(
        Modifier.fillMaxWidth().background(Palette.brandSoft, RoundedCornerShape(Radius.card)).padding(Spacing.l),
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Icon(Icons.Filled.Info, null, tint = Palette.brand, modifier = Modifier.size(18.dp).padding(top = 2.dp))
        Text(Particulier.NOTICE, style = Type.secondary, color = Palette.textPrimary)
    }
}

/** Who is signing, as what: read back before the text, so a typo in the
 *  SIRET is caught here rather than on the PDF. */
@Composable
private fun Summary(model: OnboardingModel) {
    val d = model.draft
    val lines = listOfNotNull(
        "Signataire" to (d?.fullName ?: ""),
        "Statut" to listOfNotNull(model.status?.label, d?.legalForm).joinToString(" · "),
        if (model.status == BusinessStatus.Societe && !d?.companyName.isNullOrBlank()) "Société" to (d?.companyName ?: "") else null,
        if (!d?.siret.isNullOrBlank()) "SIRET" to groupedSiret(d?.siret ?: "") else null,
        "Adresse" to listOfNotNull(d?.address, listOfNotNull(d?.postalCode, d?.city).joinToString(" ")).joinToString(", "),
    )
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        lines.forEach { (label, value) ->
            Row {
                Text(label, style = Type.caption, color = Palette.textSecondary, modifier = Modifier.width(90.dp).padding(top = 2.dp))
                Text(value, style = Type.secondary, color = Palette.textPrimary)
            }
        }
        TextLink("Modifier", modifier = Modifier.padding(start = 0.dp)) { model.back() }
    }
}

// ------------------------------------------------------------------ 4. done

@Composable
private fun ColumnScope.DoneStep(model: OnboardingModel, onFinished: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var sealed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { sealed = true }
    val pop by animateFloatAsState(if (sealed) 1f else 0.3f, spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessLow), label = "seal")
    val reveal by animateFloatAsState(if (sealed) 1f else 0f, tween(500, delayMillis = 250), label = "reveal")

    Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Spacing.gutter),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(Spacing.xl * 2))
        Box(Modifier.height(170.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
            (0 until 3).forEach { ring ->
                val s by animateFloatAsState(if (sealed) 1f else 0.6f,
                    spring(dampingRatio = 0.65f, stiffness = Spring.StiffnessVeryLow), label = "ring$ring")
                Box(Modifier.size((96 + ring * 34).dp).scale(s).alpha(if (sealed) 1f else 0f)
                    .border(1.5.dp, Palette.success.copy(alpha = 0.35f - ring * 0.1f), CircleShape))
            }
            Box(Modifier.size(96.dp).background(Palette.successSoft, CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Verified, null, tint = Palette.success, modifier = Modifier.size(46.dp).scale(pop))
            }
        }
        Column(Modifier.padding(top = Spacing.l).alpha(reveal), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Text("Contrat signé", style = display30, color = Palette.textPrimary)
            Text("Bienvenue dans le réseau Trinity Énergie${if (model.firstName.isEmpty()) "" else ", ${model.firstName}"}. Vous pouvez recommander vos premiers contacts.",
                style = Type.body, color = Palette.textSecondary, textAlign = TextAlign.Center)
        }
        model.signed?.let { signed ->
            Column(Modifier.padding(top = Spacing.xl).fillMaxWidth().alpha(reveal).cardSurface().padding(Spacing.l),
                verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                DoneRow("Statut", if (signed.businessStatus == BusinessStatus.Independant) "Indépendant · Particulier" else signed.businessStatus.label)
                DoneRow("Signé le", signedAtFormat.format(signed.signedAt.atZone(ZoneId.systemDefault())))
                DoneRow("Signature", if (signed.otpVerified) "Code SMS vérifié" + (signed.otpPhone?.let { " · $it" } ?: "") else "Depuis votre compte")
                DoneRow("Référence", signed.reference)
            }
        }
        Spacer(Modifier.height(Spacing.l))
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = Spacing.gutter, vertical = Spacing.m).alpha(reveal),
        verticalArrangement = Arrangement.spacedBy(Spacing.m), horizontalAlignment = Alignment.CenterHorizontally) {
        model.errorMessage?.let { Text(it, style = Type.caption, color = Palette.textSecondary, textAlign = TextAlign.Center) }
        val signed = model.signed
        SecondaryActionButton(if (model.isPreparingPdf) "Préparation du PDF…" else "Voir mon contrat (PDF)", icon = Icons.Filled.Description,
            enabled = !model.isPreparingPdf) {
            scope.launch { model.openPdf()?.let { bytes -> Files.open(context, bytes, signed?.fileName ?: "Contrat apporteur.pdf") } }
        }
        PrimaryActionButton("Accéder à mon espace", onClick = onFinished)
    }
}

@Composable
private fun DoneRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Type.caption, color = Palette.textSecondary)
        Spacer(Modifier.width(Spacing.m))
        Text(value, style = Type.secondary, color = Palette.textPrimary, textAlign = TextAlign.End, modifier = Modifier.weight(1f))
    }
}
