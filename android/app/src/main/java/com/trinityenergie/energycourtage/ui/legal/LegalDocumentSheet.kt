package com.trinityenergie.energycourtage.ui.legal

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.core.sha256Hex
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.LegalRepository
import com.trinityenergie.energycourtage.data.legal
import com.trinityenergie.energycourtage.model.LegalDocument
import com.trinityenergie.energycourtage.model.LegalText
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.SecondaryActionButton
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Sora
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.Instant

/** The documents everyone has to have accepted to use the app. The mandate is
 *  not one of them: only an apporteur signs it, and the database already
 *  refuses to invoice anyone without it. */
private val requiredDocuments = setOf("cgu", "confidentialite")

/**
 * The keys of the required documents (`cgu`, `confidentialite`) this person
 * has not accepted in their published version, in the server's order -- a
 * first launch, or a revised CGU. Present them one at a time with
 * `LegalDocumentSheet(required = true)` and ask again when each closes, as
 * RootView does. Empty in the demo, and when the list cannot be read:
 * offline, presenting from a stale list would reopen the sheet every time.
 */
suspend fun Dependencies.outstandingRequiredDocuments(): List<String> {
    if (isDemo) return emptyList()
    return try {
        legal().documents().filter { !it.accepted && it.key in requiredDocuments }.map { it.key }
    } catch (e: Exception) {
        emptyList()
    }
}

/** Loads the published documents and records acceptance of the exact text
 *  (iOS LegalViewModel). */
class LegalModel(private val repository: LegalRepository) {
    var documents by mutableStateOf<List<LegalDocument>>(emptyList()); private set
    var errorMessage by mutableStateOf<String?>(null); private set
    /** Set after the first load, so "not published" can be told from "still loading". */
    var hasLoaded by mutableStateOf(false); private set
    var isWorking by mutableStateOf(false); private set
    /** Acceptances that went through, for their vibration. */
    var acceptances by mutableIntStateOf(0); private set

    suspend fun load() {
        try {
            documents = repository.documents()
            errorMessage = null
        } catch (e: Exception) {
            errorMessage = e.message ?: "Une erreur est survenue. Réessayez."
        }
        hasLoaded = true
    }

    /** Hashes what was displayed rather than trusting the `sha256` that came
     *  with the row: if the two disagree the text was altered in transit, and
     *  sending back the server's own hash would paper over exactly that.
     *  True once this document is accepted. */
    suspend fun accept(document: LegalDocument): Boolean {
        isWorking = true
        try {
            val rendered = sha256Hex(document.body)
            if (rendered != document.sha256) {
                errorMessage = "Le document affiché ne correspond pas à celui publié. " +
                    "Réessayez ; si le problème persiste, contactez Trinity Énergie."
                return false
            }
            repository.accept(document.key, rendered)
            acceptances += 1
            load()
            errorMessage = null
            return documents.firstOrNull { it.key == document.key }?.accepted == true
        } catch (e: Exception) {
            errorMessage = e.message ?: "Une erreur est survenue. Réessayez."
            return false
        } finally {
            isWorking = false
        }
    }
}

/**
 * Shows a legal document in full and records acceptance of the exact text
 * (iOS LegalDocumentView). The accept button only works once the text has
 * been scrolled to its end, and what is sent is the digest of the bytes
 * shown. With [required], there is no close control while the document is
 * there to be accepted.
 *
 * [onDismiss] closes the sheet (the close control, or back); [onAccepted] is
 * called instead once the document is accepted, and the caller closes it.
 */
@Composable
fun LegalDocumentSheet(deps: Dependencies, key: String, required: Boolean, onDismiss: () -> Unit, onAccepted: () -> Unit) {
    val model = remember(deps) { LegalModel(deps.legal()) }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    LaunchedEffect(model) { model.load() }
    LaunchedEffect(model.acceptances) { if (model.acceptances > 0) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }

    val document = model.documents.firstOrNull { it.key == key }
    val closable = !required || document == null || document.accepted

    FullScreenSheet(title = document?.title ?: "Document", onDismiss = if (closable) onDismiss else null, scrolls = false) {
        when {
            document != null -> {
                val scroll = rememberScrollState()
                val hasReadToEnd = rememberReadToEnd(scroll)
                Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(scroll).padding(vertical = Spacing.s),
                    verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                    SelectionContainer { LegalTextView(document.body) }
                    Text("Version ${document.version}", style = Type.caption, color = Palette.textSecondary)
                }
                HorizontalDivider(color = Palette.hairline)
                Column(Modifier.fillMaxWidth().padding(vertical = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    model.errorMessage?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
                    if (document.accepted) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            Icon(Icons.Filled.CheckCircle, null, tint = Palette.success, modifier = Modifier.size(20.dp))
                            Text("Accepté", style = Type.body, color = Palette.success)
                        }
                    } else {
                        if (!hasReadToEnd) {
                            Text("Faites défiler jusqu'à la fin pour accepter.", style = Type.secondary, color = Palette.textSecondary)
                        }
                        PrimaryActionButton(
                            if (model.isWorking) "Enregistrement…" else "J'accepte",
                            enabled = !model.isWorking && hasReadToEnd,
                        ) {
                            scope.launch {
                                if (model.accept(document)) {
                                    if (deps.isDemo && key == "mandat_facturation") recordDemoMandate(deps)
                                    onAccepted()
                                }
                            }
                        }
                    }
                }
            }
            model.errorMessage != null -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.l, Alignment.CenterVertically)) {
                Text(model.errorMessage ?: "", style = Type.secondary, color = Palette.destructive)
                SecondaryActionButton("Réessayer") { scope.launch { model.load() } }
            }
            model.hasLoaded -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Ce document n'est pas encore publié.", style = Type.body, color = Palette.textSecondary)
            }
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { LoadingBlock() }
        }
    }
}

/**
 * The billing mandate (`mandat_facturation`), opened from Home's notice or the
 * profile: the same sheet as any legal document, not required. [onSigned] is
 * called once it is accepted -- close the sheet and refresh what showed the
 * notice; [onDismiss] when it is closed without signing.
 */
@Composable
fun MandateSheet(deps: Dependencies, onDismiss: () -> Unit, onSigned: () -> Unit) =
    LegalDocumentSheet(deps, key = "mandat_facturation", required = false, onDismiss = onDismiss, onAccepted = onSigned)

/** The demo's profile has no server to set billing_mandate_signed_at from the
 *  acceptance, so the demo records it, and the notice on Accueil goes. */
private suspend fun recordDemoMandate(deps: Dependencies) {
    runCatching {
        val profile = deps.profiles.currentProfile()
        if (profile.billingMandateSignedAt == null) deps.profiles.save(profile.copy(billingMandateSignedAt = Instant.now()))
    }
}

/**
 * True once the text has been scrolled to its end -- or fits without
 * scrolling. Measured on the scroll position, not on the text appearing:
 * agreeing to a contract you have not scrolled through is what this stops.
 * Stays true once reached.
 */
@Composable
internal fun rememberReadToEnd(scroll: ScrollState): Boolean {
    var reached by remember { mutableStateOf(false) }
    LaunchedEffect(scroll) {
        // maxValue is Int.MAX_VALUE until the content has been measured
        snapshotFlow { scroll.maxValue != Int.MAX_VALUE && !scroll.canScrollForward }.first { it }
        reached = true
    }
    return reached
}

private val headingStyle = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, lineHeight = 24.sp)

private fun inline(text: String): AnnotatedString = buildAnnotatedString {
    for (run in LegalText.runs(text)) {
        if (run.bold) withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(run.text) } else append(run.text)
    }
}

/** The legal texts' little Markdown, set as the app sets text: Sora headings,
 *  blue-dotted bullets, **bold** inline. */
@Composable
fun LegalTextView(markdown: String, modifier: Modifier = Modifier) {
    val blocks = remember(markdown) { LegalText.parse(markdown) }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        for (block in blocks) when (block) {
            is LegalText.Block.Heading -> Text(inline(block.text), style = headingStyle, color = Palette.textPrimary,
                modifier = Modifier.padding(top = Spacing.s))
            is LegalText.Block.Bullet -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.padding(top = 9.dp).size(5.dp).background(Palette.brand, CircleShape))
                Text(inline(block.text), style = Type.body, color = Palette.textPrimary)
            }
            is LegalText.Block.Paragraph -> Text(inline(block.text), style = Type.body.copy(lineHeight = 26.sp), color = Palette.textPrimary)
        }
    }
}
