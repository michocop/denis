package com.trinityenergie.energycourtage.ui.profile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import kotlinx.coroutines.launch

object BillingRules {
    /** Checked while the person is still looking at it, rather than printed
     *  on an invoice that is then kept ten years. */
    fun validationProblem(siret: String?, postalCode: String?): String? {
        val s = siret.orEmpty().filter { !it.isWhitespace() }
        if (s.isNotEmpty() && (s.length != 14 || !s.all { it.isDigit() })) return "Le SIRET compte 14 chiffres."
        val p = postalCode.orEmpty().trim()
        if (p.isNotEmpty() && (p.length != 5 || !p.all { it.isDigit() })) return "Le code postal compte 5 chiffres."
        return null
    }

    /** What an invoice in this person's name needs: where they can be
     *  reached. The SIRET is not required -- an occasional apporteur has none. */
    fun hasBillingAddress(p: Profile) = listOf(p.address, p.postalCode, p.city).none { it.isNullOrBlank() }
}

/**
 * Who the apporteur is on their invoices (Features/Profile/BillingDetailsView.swift):
 * copied onto each invoice when it is issued; invoices already issued keep
 * what they said.
 */
@Composable
internal fun BillingDetailsScreen(profile: Profile, save: suspend (Profile) -> Unit, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf(profile) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val problem = BillingRules.validationProblem(draft.siret, draft.postalCode)

    FullScreenSheet("Informations de facturation", onDismiss = { if (!saving) onDismiss() }) {
        Text("Ces informations figurent sur les factures établies en votre nom. Les factures déjà émises ne sont pas modifiées.",
            style = Type.secondary, color = Palette.textSecondary)

        LabelledField("Raison sociale (facultatif)", draft.companyName.orEmpty(), { draft = draft.copy(companyName = it) },
            placeholder = "Nom de votre entreprise", keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        LabelledField("Statut (facultatif)", draft.legalForm.orEmpty(), { draft = draft.copy(legalForm = it) },
            placeholder = "Micro-entreprise, SASU…")
        LabelledField("SIRET (facultatif)", draft.siret.orEmpty(), { draft = draft.copy(siret = it) },
            placeholder = "14 chiffres", keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
        LabelledField("Adresse", draft.address.orEmpty(), { draft = draft.copy(address = it) },
            placeholder = "Numéro et rue", keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            LabelledField("Code postal", draft.postalCode.orEmpty(), { draft = draft.copy(postalCode = it) }, Modifier.width(130.dp),
                placeholder = "59000", keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            LabelledField("Ville", draft.city.orEmpty(), { draft = draft.copy(city = it) }, Modifier.weight(1f),
                placeholder = "Ville", keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        }
        LabelledField("Téléphone", draft.phone.orEmpty(), { draft = draft.copy(phone = it) },
            placeholder = "06 12 34 56 78", keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone))

        (problem ?: error)?.let { Text(it, style = Type.secondary, color = Palette.destructive) }

        PrimaryActionButton(if (saving) "Enregistrement…" else "Enregistrer", enabled = problem == null, working = saving) {
            saving = true
            scope.launch {
                try {
                    save(draft)
                    onDismiss()
                } catch (e: Exception) {
                    error = "Ces informations n'ont pas pu être enregistrées : " + (e.message ?: "")
                }
                saving = false
            }
        }
    }
}
