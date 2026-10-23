package com.trinityenergie.energycourtage.ui.invoices

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.core.Money
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.invoices
import com.trinityenergie.energycourtage.data.sms
import com.trinityenergie.energycourtage.data.smsDemoHint
import com.trinityenergie.energycourtage.model.InvoiceDocument
import com.trinityenergie.energycourtage.model.plainRate
import com.trinityenergie.energycourtage.pdf.InvoicePdf
import com.trinityenergie.energycourtage.ui.components.ConfirmDialog
import com.trinityenergie.energycourtage.ui.components.FieldBox
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.sms.SigningSheet
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Sora
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.TrinityLogo
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch

/**
 * The facture / attestation d'apport d'affaires, with the dual-signature
 * panel (iOS InvoiceView). Signs as `deps.fullName`, for the company when
 * `deps.role.isAdmin`, for the apporteur otherwise. [onDismiss] closes it.
 */
@Composable
fun InvoiceSheet(deps: Dependencies, invoiceId: String, onDismiss: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val model = remember(deps, invoiceId) {
        InvoiceModel(invoiceId, deps.invoices(), deps.sms()) { InvoicePdf.render(it, context) }
    }
    val isAdmin = deps.role.isAdmin
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    var confirmsSigning by remember { mutableStateOf(false) }
    var showsCreditNote by remember { mutableStateOf(false) }
    var openingPreview by remember { mutableStateOf(false) }

    LaunchedEffect(model) {
        model.load()
        if (model.document?.isFullySigned == true) model.preparePdf()
    }
    LaunchedEffect(model.signatures) { if (model.signatures > 0) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }

    FullScreenSheet(title = model.document?.let { if (it.isCreditNote) "Avoir" else "Facture" } ?: "Facture", onDismiss = onDismiss) {
        val doc = model.document
        when {
            doc != null -> {
                DocumentCard(doc, isAdmin)
                if (!doc.isFullySigned) {
                    SecondaryActionButton(if (openingPreview) "Préparation du PDF…" else "Voir le PDF", icon = Icons.Filled.Description,
                        enabled = !openingPreview) {
                        openingPreview = true
                        scope.launch {
                            model.previewPdf()?.let { Files.open(context, it, "${doc.number} (aperçu).pdf") }
                            openingPreview = false
                        }
                    }
                }
                SignaturePanel(doc, deps.fullName, isAdmin, model) { confirmsSigning = true }
                if (doc.isFullySigned) PdfPanel(model) { bytes -> Files.share(context, bytes, "${doc.number}.pdf", "application/pdf") }
                if (isAdmin && doc.isFullySigned) CorrectionPanel(model) { showsCreditNote = true }
            }
            model.errorMessage != null -> Column(Modifier.padding(vertical = 48.dp), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                Text(model.errorMessage ?: "", style = Type.secondary, color = Palette.destructive)
                SecondaryActionButton("Réessayer") { scope.launch { model.load() } }
            }
            else -> LoadingBlock(Modifier.padding(vertical = 48.dp))
        }
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            TextLink("Fermer", color = Palette.textSecondary, onClick = onDismiss)
        }
    }

    val doc = model.document
    if (confirmsSigning && doc != null) {
        ConfirmDialog(
            title = "Signer la facture ${doc.number} ?",
            message = "Votre signature électronique vaut accord sur ce document, pour un montant de ${doc.amount.ttc.toBigDecimalOrNull()?.let { com.trinityenergie.energycourtage.core.Money.euros(it, cents = true) } ?: "${doc.amount.ttc} ${doc.amount.currency}"} TTC. Elle ne pourra pas être retirée.",
            confirm = "Signer",
            onConfirm = { confirmsSigning = false; scope.launch { model.startSigning(asCompany = isAdmin) } },
            onDismiss = { confirmsSigning = false },
        )
    }

    if (showsCreditNote) {
        var reason by remember { mutableStateOf("") }
        ConfirmDialog(
            title = "Établir un avoir",
            message = "Le motif figure sur l'avoir et reste au registre. La facture d'origine est conservée telle quelle.",
            confirm = "Établir",
            destructive = true,
            onConfirm = {
                val r = reason.trim()
                if (r.isNotEmpty()) {
                    showsCreditNote = false
                    scope.launch { model.issueCreditNote(r) }
                }
            },
            onDismiss = { showsCreditNote = false },
            extra = {
                FieldBox {
                    BasicTextField(reason, { reason = it }, singleLine = true,
                        textStyle = Type.body.copy(color = Palette.textPrimary), cursorBrush = SolidColor(Palette.brand),
                        modifier = Modifier.fillMaxWidth(),
                        decorationBox = { inner ->
                            if (reason.isEmpty()) Text("Motif", style = Type.body, color = Palette.textSecondary.copy(alpha = 0.6f))
                            inner()
                        })
                }
            },
        )
    }

    model.signingStep?.let { step ->
        SigningSheet(
            step = step,
            phoneExplanation = "Votre signature se confirme avec un code reçu par SMS. Ce même code validera votre numéro : un seul SMS.",
            codeTitle = "Signer la facture",
            phoneCodeExplanation = "Ce code confirme votre signature et votre numéro.",
            codeExplanation = "Ce code confirme que c'est bien vous qui signez ${doc?.number ?: "cette facture"}. Il reste valable 10 minutes pour vos autres signatures.",
            initialPhone = "",
            demoHint = deps.smsDemoHint,
            dismissible = true,
            send = { phone, resend -> model.requestSigningCode(phone, resend) },
            confirm = { model.confirmSigningCode(it) },
            onConfirmed = { scope.launch { model.codeConfirmed() } },
            onCancel = { model.signingStep = null },
        )
    }
}

// ---------------------------------------------------------------- document

private fun euros(amount: String, cents: Boolean = true): String =
    amount.toBigDecimalOrNull()?.let { Money.euros(it, cents) } ?: amount

private val capsLabel = Type.caption.copy(letterSpacing = 1.1.sp)
private val tinyCaps = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 10.sp, letterSpacing = 1.sp)

private fun myRole(isAdmin: Boolean) = if (isAdmin) "entreprise" else "apporteur"

/** Where the invoice stands, said once, with its colour. */
private fun statusOf(doc: InvoiceDocument, isAdmin: Boolean): Pair<String, Color> = when {
    doc.status == "void" -> "Annulée" to Palette.destructive
    doc.isFullySigned -> (if (doc.status == "paid") "Payée" else "Signée") to Palette.successText
    doc.acceptsSignatures && !doc.isSignedBy(myRole(isAdmin)) -> "À signer" to Palette.rewardText
    else -> "En attente" to Palette.ice
}

@Composable
private fun DocumentCard(doc: InvoiceDocument, isAdmin: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        Hero(doc, isAdmin)
        Parties(doc)
        LinesAndTotals(doc)
        Attestation(doc)
        Mentions(doc)
    }
}

/** The document's identity: kind, number, amount, dates, state. */
@Composable
private fun Hero(doc: InvoiceDocument, isAdmin: Boolean) {
    val (label, tint) = statusOf(doc, isAdmin)
    val shape = RoundedCornerShape(Radius.card)
    Box(
        Modifier.fillMaxWidth().clip(shape)
            .background(Brush.linearGradient(listOf(Palette.brandFill, Palette.navy)), shape)
    ) {
        Box(Modifier.align(Alignment.BottomEnd).offset(x = 26.dp, y = 22.dp).alpha(0.08f)) {
            TrinityLogo(size = 130.dp, lineColor = Color.White)
        }
        Column(Modifier.fillMaxWidth().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(if (doc.isCreditNote) "AVOIR" else "FACTURE", style = Type.caption.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 1.6.sp), color = Palette.ice)
                    Text("N° ${doc.number}", style = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 20.sp), color = Color.White)
                    val original = doc.correctsNumber
                    if (doc.isCreditNote && original != null) Text("sur la facture $original", style = Type.caption, color = Palette.ice)
                }
                Text(label, style = Type.caption.copy(fontWeight = FontWeight.SemiBold), color = tint, maxLines = 1,
                    modifier = Modifier
                        .background(Color.Black.copy(alpha = 0.25f), RoundedCornerShape(50))
                        .border(1.dp, tint.copy(alpha = 0.5f), RoundedCornerShape(50))
                        .padding(horizontal = 10.dp, vertical = 5.dp))
            }
            Text(euros(doc.amount.ttc), style = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 38.sp), color = Color.White,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.xl)) {
                Fact("Émise le", doc.issuedOn)
                doc.dueOn?.let { Fact("Échéance", it) }
                Fact("Règlement", doc.paymentMethod)
            }
        }
    }
}

@Composable
private fun Fact(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label.uppercase(), style = tinyCaps, color = Palette.ice.copy(alpha = 0.8f))
        Text(value, style = Type.secondary.copy(fontWeight = FontWeight.SemiBold), color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The supplier (the apporteur, in whose name it is issued) and the client. */
@Composable
private fun Parties(doc: InvoiceDocument) {
    val a = doc.apporteur
    val supplier = listOfNotNull(a.company, a.address, listOfNotNull(a.postalCode, a.city).joinToString(" "), a.siret?.let { "SIRET $it" })
        .filter { it.isNotEmpty() }
    val client = doc.customer?.let { c -> c.legalName to listOf(c.address, "${c.postalCode} ${c.city}", "SIREN ${c.siren}") }
        ?: ((doc.issuer.company ?: doc.issuer.name) to listOfNotNull(doc.issuer.city))
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        PartyCard("FOURNISSEUR", a.name, supplier, Modifier.weight(1f))
        PartyCard("CLIENT", client.first, client.second, Modifier.weight(1f))
    }
}

@Composable
private fun PartyCard(label: String, name: String, lines: List<String>, modifier: Modifier) {
    Column(modifier.fillMaxHeight().cardSurface(18.dp).padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = TextStyle(fontWeight = FontWeight.Bold, fontSize = 10.sp, letterSpacing = 1.2.sp), color = Palette.brand)
        Text(name, style = Type.label.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
        lines.forEach { Text(it, style = Type.caption, color = Palette.textSecondary) }
    }
}

/** What is invoiced, then HT / TVA / TTC. */
@Composable
private fun LinesAndTotals(doc: InvoiceDocument) {
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Row {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(doc.attestation.prestation, style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                Text("Mise en relation avec ${doc.attestation.avec}, le ${doc.attestation.intervenueLe}", style = Type.caption, color = Palette.textSecondary)
            }
            Spacer(Modifier.width(Spacing.m))
            Text(euros(doc.amount.ht), style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
        }
        HorizontalDivider(color = Palette.hairline)
        Total("Total HT", euros(doc.amount.ht))
        Total("TVA (${doc.amount.vatRate.plainRate()} %)", euros(doc.amount.vat))
        val shape = RoundedCornerShape(14.dp)
        Row(
            Modifier.fillMaxWidth().background(Palette.navy, shape).border(1.dp, Palette.brand.copy(alpha = 0.4f), shape)
                .padding(horizontal = Spacing.l, vertical = Spacing.m),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(if (doc.isCreditNote) "Total TTC à déduire" else "Total TTC", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Color.White,
                modifier = Modifier.weight(1f))
            Text(euros(doc.amount.ttc), style = Type.amount, color = Color.White)
        }
    }
}

@Composable
private fun Total(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, style = Type.secondary, color = Palette.textSecondary, modifier = Modifier.weight(1f))
        Text(value, style = Type.secondary, color = Palette.textPrimary)
    }
}

/** The apporteur's attestation, as what it is: their statement. */
@Composable
private fun Attestation(doc: InvoiceDocument) {
    if (doc.isCreditNote) return
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).padding(horizontal = Spacing.s), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Box(Modifier.width(3.dp).fillMaxHeight().background(Palette.brand, RoundedCornerShape(2.dp)))
        Text(InvoicePdf.attestationSentence(doc), style = Type.secondary.copy(fontStyle = FontStyle.Italic), color = Palette.textPrimary)
    }
}

/** Every mandatory mention, folded: they are on the document and the PDF,
 *  but do not need to fill the screen. */
@Composable
private fun Mentions(doc: InvoiceDocument) {
    var open by remember { mutableStateOf(false) }
    val turn by animateFloatAsState(if (open) 180f else 0f, label = "chevron")
    Column(Modifier.fillMaxWidth().cardSurface(18.dp).padding(Spacing.l)) {
        Row(Modifier.fillMaxWidth().clickable { open = !open }, verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Icon(Icons.AutoMirrored.Filled.MenuBook, null, tint = Palette.textPrimary, modifier = Modifier.size(18.dp))
            Text("Mentions légales", style = Type.label, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ExpandMore, if (open) "Replier" else "Déplier", tint = Palette.textSecondary, modifier = Modifier.rotate(turn))
        }
        AnimatedVisibility(open) {
            Column(Modifier.padding(top = Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                listOfNotNull(doc.selfBillingMention, doc.legalMentions, doc.latePaymentMention,
                    "Fait à ${doc.place}, le ${doc.issuedOn}.", doc.taxNotice)
                    .forEach { Text(it, style = Type.caption, color = Palette.textSecondary) }
            }
        }
    }
}

// ------------------------------------------------------------ signatures

@Composable
private fun SignaturePanel(doc: InvoiceDocument, signerName: String, isAdmin: Boolean, model: InvoiceModel, onSign: () -> Unit) {
    val mine = myRole(isAdmin)
    val otherParty = if (isAdmin) "de l'apporteur" else "de l'entreprise"
    val canSign = doc.acceptsSignatures && !doc.isSignedBy(mine)
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        if (canSign) {
            Text("VOUS ALLEZ SIGNER EN TANT QUE", style = capsLabel, color = Palette.textSecondary)
            Text(signerName, style = Type.cardTitle, color = Palette.textPrimary)
            HorizontalDivider(color = Palette.hairline)
        }
        doc.signatures.forEach { s ->
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalAlignment = Alignment.Top) {
                Icon(if (s.signed) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null,
                    tint = if (s.signed) Palette.success else Palette.pendingRing, modifier = Modifier.size(22.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                        Text(if (s.role == "apporteur") "L'apporteur" else "L'entreprise", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                        if (!s.signed) {
                            Text("En attente", style = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 11.sp), color = Palette.rewardText,
                                modifier = Modifier.background(Palette.rewardSoft, RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 3.dp))
                        }
                    }
                    Text(s.name, style = Type.secondary, color = Palette.textSecondary)
                    if (s.signed) {
                        s.signedAt?.let { Text("Signé le ${Dates.mediumTime(it)}", style = Type.caption, color = Palette.textSecondary) }
                        if (s.smsVerified == true) {
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Filled.VerifiedUser, null, tint = Palette.successText, modifier = Modifier.size(14.dp))
                                Text("Confirmé par SMS" + (s.smsPhone?.let { " · $it" } ?: ""),
                                    style = Type.caption.copy(fontWeight = FontWeight.SemiBold), color = Palette.successText)
                            }
                        }
                    }
                }
            }
        }
        when {
            doc.status == "void" -> Text("Cette facture a été annulée et ne peut plus être signée.", style = Type.secondary, color = Palette.textSecondary)
            canSign -> {
                // one tap used to sign; it asks first now
                PrimaryActionButton(if (model.isWorking) "Signature…" else "Signer", enabled = !model.isWorking, working = model.isWorking, onClick = onSign)
                model.errorMessage?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
            }
            !doc.isFullySigned -> Text("Vous avez signé. En attente de la signature $otherParty.", style = Type.secondary, color = Palette.textSecondary)
        }
    }
}

/** Once both parties have signed, the invoice exists as a file that has to be
 *  kept for ten years -- by the company and by the apporteur, who declares it. */
@Composable
private fun PdfPanel(model: InvoiceModel, onShare: (ByteArray) -> Unit) {
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text("DOCUMENT", style = capsLabel, color = Palette.textSecondary)
        val bytes = model.pdf
        when {
            bytes != null -> {
                Row(Modifier.clickable { onShare(bytes) }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Icon(Icons.Filled.IosShare, null, tint = Palette.brand, modifier = Modifier.size(20.dp))
                    Text("Enregistrer ou envoyer le PDF", style = Type.body, color = Palette.brand)
                }
                Text("À conserver dix ans : c'est cette facture que vous déclarez.", style = Type.secondary, color = Palette.textSecondary)
            }
            model.isPreparingPdf -> Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(color = Palette.brand, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                Text("Préparation du PDF…", style = Type.secondary, color = Palette.textSecondary)
            }
            else -> {
                model.errorMessage?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
                TextLink("Réessayer") { scope.launch { model.preparePdf() } }
            }
        }
    }
}

/** A signed invoice cannot be edited or deleted; an error is corrected by a
 *  credit note, a new document in the same series. */
@Composable
private fun CorrectionPanel(model: InvoiceModel, onCreditNote: () -> Unit) {
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text("CORRECTION", style = capsLabel, color = Palette.textSecondary)
        if (model.creditNoteIssued) {
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.CheckCircle, null, tint = Palette.success, modifier = Modifier.size(20.dp))
                Text("Avoir établi", style = Type.body, color = Palette.success)
            }
            Text("La commission est de nouveau due : une facture corrigée peut être établie.", style = Type.secondary, color = Palette.textSecondary)
        } else {
            Text("Cette facture est scellée. Une erreur se corrige par un avoir — une nouvelle pièce du même registre portant le montant négatif — jamais par une modification.",
                style = Type.secondary, color = Palette.textSecondary)
            model.errorMessage?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
            if (model.isWorking) LoadingBlock()
            else TextLink("Établir un avoir", color = Palette.destructive, onClick = onCreditNote)
        }
    }
}
