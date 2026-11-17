package com.trinityenergie.energycourtage.ui.recommendations

import java.time.Instant
import com.trinityenergie.energycourtage.model.RecoDates
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.RecommendationEvents
import com.trinityenergie.energycourtage.data.documents
import com.trinityenergie.energycourtage.data.recommendations
import com.trinityenergie.energycourtage.model.DocumentException
import com.trinityenergie.energycourtage.model.DocumentUpload
import com.trinityenergie.energycourtage.model.DuplicateCheck
import com.trinityenergie.energycourtage.model.RecommendationDraft
import com.trinityenergie.energycourtage.ui.components.FieldBox
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.documents.AddDocumentButton
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The create-recommendation form (iOS CreateRecommendationView).
 *
 * The consent toggle is a legal requirement, not a courtesy: the filleul
 * never signed up, so storing their name and number needs a lawful basis,
 * and the apporteur confirming they informed them is it. The duplicate check
 * runs as they type -- learning after the whole form that the lead is taken
 * is the worst moment. The bill, attached before the lead exists, is sent
 * right after it is created.
 *
 * [onCreated] is called once the recommendation exists; [onDismiss] closes
 * the form -- right after [onCreated] when every attachment went through,
 * otherwise when the person closes it after reading which ones failed.
 */
@Composable
fun CreateRecommendationSheet(deps: Dependencies, onDismiss: () -> Unit, onCreated: () -> Unit) {
    val recommendations = remember(deps) { deps.recommendations() }
    val documents = remember(deps) { deps.documents() }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current

    var draft by remember { mutableStateOf(RecommendationDraft()) }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var created by remember { mutableStateOf(false) }
    var duplicate by remember { mutableStateOf(DuplicateCheck()) }
    val attachments = remember { mutableStateListOf<DocumentUpload>() }

    // debounced: a phone number typed digit by digit is one request
    LaunchedEffect(draft.phone, draft.email) {
        if (!draft.worthDuplicateCheck) { duplicate = DuplicateCheck(); return@LaunchedEffect }
        delay(400)
        try { duplicate = recommendations.checkDuplicate(draft.phone, draft.email) }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { duplicate = DuplicateCheck() } // a warning, not a gate: a stale one must not block
    }

    LaunchedEffect(error) { if (error != null) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }

    val canSubmit = draft.isValid && !duplicate.blocksSubmission && !created

    FullScreenSheet(title = "Nouvelle recommandation", onDismiss = onDismiss) {
        Text("Qui souhaitez-vous recommander ?", style = Type.body, color = Palette.textSecondary)

        LabelledField("Prénom", draft.firstName, { draft = draft.copy(firstName = it) }, placeholder = "Prénom du filleul",
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        LabelledField("Nom", draft.lastName, { draft = draft.copy(lastName = it) }, placeholder = "Nom du filleul",
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        LabelledField("Téléphone", draft.phone, { draft = draft.copy(phone = it) }, placeholder = "+33 6 …",
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone))
        LabelledField("Email (facultatif)", draft.email, { draft = draft.copy(email = it.trim()) }, placeholder = "adresse@exemple.fr",
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, autoCorrectEnabled = false,
                capitalization = KeyboardCapitalization.None))
        LabelledField("Société (facultatif)", draft.company, { draft = draft.copy(company = it) }, placeholder = "Raison sociale",
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))

        CommentField(draft.comment) { draft = draft.copy(comment = it.take(RecommendationDraft.COMMENT_LIMIT)) }

        AppointmentBlock(draft.appointmentAt) { draft = draft.copy(appointmentAt = it) }

        // the filleul's bill
        Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Text("Facture d'énergie du filleul", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
            Text("Facultatif, mais c'est elle qui permet de lui proposer une meilleure offre.", style = Type.secondary, color = Palette.textSecondary)
            attachments.forEachIndexed { index, upload ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (upload.isPdf) Icons.Filled.PictureAsPdf else Icons.Filled.Image, null, tint = Palette.brand, modifier = Modifier.size(20.dp))
                    Row(Modifier.width(Spacing.s)) {}
                    Text(upload.filename, style = Type.label, color = Palette.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f))
                    IconButton(onClick = { attachments.removeAt(index) }, modifier = Modifier.size(36.dp)) {
                        Icon(Icons.Filled.Cancel, "Retirer ${upload.filename}", tint = Palette.textSecondary)
                    }
                }
            }
            AddDocumentButton(
                title = if (attachments.isEmpty()) "Joindre la facture" else "Ajouter un document",
                enabled = !saving && !created,
                onPicked = { picked ->
                    val (fit, tooLarge) = picked.partition { it.data.size <= DocumentUpload.MAX_BYTES }
                    attachments += fit
                    if (tooLarge.isNotEmpty()) error = DocumentException(DocumentException.Kind.TooLarge).message
                },
                onError = { error = it },
            )
        }

        duplicate.warning?.let { DuplicateWarning(it, duplicate.blocksSubmission) }

        ConsentToggle(draft.consentConfirmed) { draft = draft.copy(consentConfirmed = it) }

        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }

        PrimaryActionButton(if (saving) "Envoi…" else "Envoyer la recommandation", enabled = canSubmit && !saving, working = saving) {
            scope.launch {
                saving = true
                error = null
                try {
                    val reco = recommendations.create(draft)
                    created = true
                    // the lead exists whatever happens to the files; a file
                    // that fails can be added again from the lead's page
                    val failed = mutableListOf<String>()
                    for (upload in attachments.toList()) {
                        try { documents.add(upload, reco.id) } catch (e: CancellationException) { throw e } catch (_: Exception) { failed += upload.filename }
                    }
                    RecommendationEvents.notifyCreated()
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    onCreated()
                    if (failed.isEmpty()) onDismiss()
                    else {
                        attachments.clear()
                        error = "Recommandation envoyée, mais ces documents n'ont pas pu l'être : " +
                            failed.joinToString(", ") + ". Ajoutez-les depuis la recommandation."
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    error = e.message
                }
                saving = false
            }
        }
    }
}

/** What the fields cannot say -- the current supplier, when to call, who
 *  decides. The counter shows only near the limit. */
@Composable
private fun CommentField(value: String, onChange: (String) -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text("Commentaire (facultatif)", style = Type.caption, color = Palette.textSecondary, modifier = Modifier.padding(start = 4.dp))
        FieldBox {
            BasicTextField(
                value = value, onValueChange = onChange,
                minLines = 3, maxLines = 8,
                textStyle = Type.body.copy(color = Palette.textPrimary),
                cursorBrush = SolidColor(Palette.brand),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier.fillMaxWidth(),
                decorationBox = { inner ->
                    if (value.isEmpty()) Text("Fournisseur actuel, échéance du contrat, meilleur moment pour appeler…",
                        style = Type.body, color = Palette.textSecondary.copy(alpha = 0.6f))
                    inner()
                },
            )
        }
        if (value.length > RecommendationDraft.COMMENT_LIMIT - 200) {
            Text("${value.length} / ${RecommendationDraft.COMMENT_LIMIT}", style = Type.caption, textAlign = TextAlign.End,
                color = if (value.length >= RecommendationDraft.COMMENT_LIMIT) Palette.destructive else Palette.textSecondary,
                modifier = Modifier.fillMaxWidth())
        }
    }
}

/** Off by default: most leads are simply called back. */
@Composable
private fun AppointmentBlock(value: Instant?, onChange: (Instant?) -> Unit) {
    Column(Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Rendez-vous (facultatif)", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                Text("À renseigner seulement si un rendez-vous est nécessaire ou déjà fixé.", style = Type.secondary, color = Palette.textSecondary)
            }
            Switch(checked = value != null, onCheckedChange = { onChange(if (it) RecoDates.defaultAppointment() else null) },
                modifier = Modifier.semantics { contentDescription = "Ajouter un rendez-vous" },
                colors = SwitchDefaults.colors(
                    checkedTrackColor = Palette.brandFill, checkedThumbColor = androidx.compose.ui.graphics.Color.White,
                    uncheckedTrackColor = Palette.track, uncheckedBorderColor = Palette.hairline, uncheckedThumbColor = Palette.textSecondary))
        }
        if (value != null) AppointmentFields(value, onChange)
    }
}

@Composable
private fun ConsentToggle(checked: Boolean, onChange: (Boolean) -> Unit) {
    val text = "J'ai informé cette personne que je transmets ses coordonnées et elle en est d'accord."
    Row(
        Modifier.fillMaxWidth().background(Palette.track, RoundedCornerShape(Radius.field)).padding(Spacing.l)
            .semantics(mergeDescendants = true) { contentDescription = text; stateDescription = if (checked) "Activé" else "Désactivé" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Text(text, style = Type.secondary, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(
            checkedTrackColor = Palette.brandFill, checkedThumbColor = androidx.compose.ui.graphics.Color.White,
            uncheckedTrackColor = Palette.track, uncheckedBorderColor = Palette.hairline, uncheckedThumbColor = Palette.textSecondary))
    }
}
