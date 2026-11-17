package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import com.trinityenergie.energycourtage.model.RecoDates
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.TextLink
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Type
import kotlinx.coroutines.launch
import java.time.Instant

/** Sets, moves or removes the meeting of one lead (Features/Admin/AppointmentsView.swift). */
@Composable
fun AppointmentSheet(recommendation: Recommendation, save: suspend (Instant?) -> Unit, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var at by remember { mutableStateOf(clampFuture(recommendation.appointmentAt ?: RecoDates.defaultAppointment())) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun send(value: Instant?) {
        working = true
        scope.launch {
            try {
                save(value)
                onDismiss()
            } catch (e: Exception) {
                error = e.message
                working = false
            }
        }
    }

    FullScreenSheet(title = "Rendez-vous", onDismiss = onDismiss) {
        Text(recommendation.filleulName, style = Type.body, color = Palette.textSecondary)
        Column { AppointmentFields(at) { at = it } }
        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
        PrimaryActionButton("Enregistrer", enabled = !working, onClick = { send(at) })
        if (recommendation.appointmentAt != null) TextLink("Retirer le rendez-vous", color = Palette.destructive) { if (!working) send(null) }
    }
}
