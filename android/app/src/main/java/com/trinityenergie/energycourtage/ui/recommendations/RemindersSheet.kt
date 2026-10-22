package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.trinityenergie.energycourtage.data.RemindersRepository
import com.trinityenergie.energycourtage.model.Reminder
import com.trinityenergie.energycourtage.reminders.ReminderAlarms
import com.trinityenergie.energycourtage.ui.components.FieldBox
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * "Rappels" from the action sheet (iOS RemindersView): a quick preset, a real
 * date and time, and a way to tick one off. Each reminder is mirrored onto
 * the phone as a "Relance" notification at its due time.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun RemindersSheet(recommendationId: String, filleulName: String, repository: RemindersRepository, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var reminders by remember { mutableStateOf<List<Reminder>?>(null) }
    var label by remember { mutableStateOf("") }
    var dueAt by remember { mutableStateOf(Reminder.defaultDue()) }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var completing by remember { mutableStateOf<String?>(null) }
    var pickingDate by remember { mutableStateOf(false) }
    var pickingTime by remember { mutableStateOf(false) }

    suspend fun load() {
        reminders = try { repository.reminders(recommendationId) } catch (e: Exception) { error = e.message; reminders ?: emptyList() }
    }
    LaunchedEffect(recommendationId) { load() }

    FullScreenSheet(title = "Rappels", onDismiss = onDismiss) {
        val list = reminders
        when {
            list == null -> LoadingBlock()
            list.isNotEmpty() -> Column(
                Modifier.fillMaxWidth().cardSurface().padding(Spacing.l),
                verticalArrangement = Arrangement.spacedBy(Spacing.m),
            ) {
                Text("Rappels programmés", style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                list.forEach { reminder ->
                    ReminderRow(reminder, completing == reminder.id) {
                        if (reminder.status == Reminder.Status.Done || completing != null) return@ReminderRow
                        scope.launch {
                            completing = reminder.id
                            try {
                                repository.complete(reminder.id)
                                ReminderAlarms.cancel(context, reminder.id)
                                load()
                            } catch (e: Exception) {
                                error = e.message
                            }
                            completing = null
                        }
                    }
                }
            }
        }

        LabelledField(label = "Intitulé", value = label, onValueChange = { label = it }, placeholder = "Relancer $filleulName")

        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Reminder.presets.forEach { (title, seconds) ->
                Text(title, style = Type.secondary, color = Palette.brand, maxLines = 1,
                    modifier = Modifier.background(Palette.brandSoft, RoundedCornerShape(50))
                        .clickable(role = Role.Button) { dueAt = Instant.now().plusSeconds(seconds) }
                        .padding(horizontal = Spacing.m, vertical = 8.dp))
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Text("Échéance", style = Type.caption, color = Palette.textSecondary, modifier = Modifier.padding(start = 4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                val zoned = dueAt.atZone(ZoneId.systemDefault())
                FieldBox(Modifier.weight(1.4f).clickable(role = Role.Button) { pickingDate = true }
                    .semantics { contentDescription = "Date de l'échéance" }) {
                    Text(com.trinityenergie.energycourtage.core.Dates.medium(dueAt), style = Type.body, color = Palette.textPrimary)
                }
                FieldBox(Modifier.weight(1f).clickable(role = Role.Button) { pickingTime = true }
                    .semantics { contentDescription = "Heure de l'échéance" }) {
                    Text("%02d:%02d".format(zoned.hour, zoned.minute), style = Type.body, color = Palette.textPrimary)
                }
            }
        }

        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }

        PrimaryActionButton(if (working) "Enregistrement…" else "Programmer le rappel", enabled = !working, working = working) {
            scope.launch {
                working = true
                val text = Reminder.labelOrDefault(label, filleulName)
                // a date that has slipped into the past while the screen was open
                val due = if (dueAt.isBefore(Instant.now())) Instant.now().plusSeconds(60) else dueAt
                try {
                    val reminder = repository.schedule(recommendationId, text, due)
                    // mirrored onto the phone, so the relance fires with the app closed
                    ReminderAlarms.schedule(context, reminder.id, text, reminder.dueAt, recommendationId)
                    label = ""
                    error = null
                    load()
                } catch (e: Exception) {
                    error = e.message
                }
                working = false
            }
        }
    }

    if (pickingDate) {
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val state = rememberDatePickerState(
            initialSelectedDateMillis = dueAt.atZone(zone).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long) =
                    !Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate().isBefore(today)
                override fun isSelectableYear(year: Int) = year >= today.year
            },
        )
        DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                TextButton({
                    state.selectedDateMillis?.let { millis ->
                        val day = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
                        val time = dueAt.atZone(zone).toLocalTime()
                        dueAt = clampFuture(day.atTime(time).atZone(zone).toInstant())
                    }
                    pickingDate = false
                }) { Text("OK", style = Type.label, color = Palette.brand) }
            },
            dismissButton = { TextButton({ pickingDate = false }) { Text("Annuler", style = Type.label, color = Palette.textSecondary) } },
            colors = DatePickerDefaults.colors(containerColor = Palette.surface),
        ) {
            DatePicker(state, colors = DatePickerDefaults.colors(
                containerColor = Palette.surface,
                selectedDayContainerColor = Palette.brandFill,
                todayDateBorderColor = Palette.brand,
                todayContentColor = Palette.brand,
            ))
        }
    }

    if (pickingTime) {
        val zone = ZoneId.systemDefault()
        val current = dueAt.atZone(zone)
        val state = rememberTimePickerState(current.hour, current.minute, is24Hour = true)
        Dialog(onDismissRequest = { pickingTime = false }) {
            Column(
                Modifier.background(Palette.surface, RoundedCornerShape(Radius.modal)).padding(Spacing.xl),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Spacing.l),
            ) {
                Text("Heure de l'échéance", style = Type.label, color = Palette.textSecondary, modifier = Modifier.fillMaxWidth())
                TimePicker(state, colors = TimePickerDefaults.colors(
                    clockDialColor = Palette.track,
                    selectorColor = Palette.brandFill,
                    timeSelectorSelectedContainerColor = Palette.brandSoft,
                    timeSelectorSelectedContentColor = Palette.textPrimary,
                    timeSelectorUnselectedContainerColor = Palette.track,
                    timeSelectorUnselectedContentColor = Palette.textSecondary,
                ))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton({ pickingTime = false }) { Text("Annuler", style = Type.label, color = Palette.textSecondary) }
                    TextButton({
                        val day = dueAt.atZone(zone).toLocalDate()
                        dueAt = clampFuture(day.atTime(LocalTime.of(state.hour, state.minute)).atZone(zone).toInstant())
                        pickingTime = false
                    }) { Text("OK", style = Type.label, color = Palette.brand) }
                }
            }
        }
    }
}

/** The picker allows nothing before now, as iOS's `in: Date.now...`. */
private fun clampFuture(i: Instant): Instant = if (i.isBefore(Instant.now())) Instant.now().plusSeconds(60) else i

@Composable
private fun ReminderRow(reminder: Reminder, completing: Boolean, onComplete: () -> Unit) {
    val done = reminder.status == Reminder.Status.Done
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        if (completing) CircularProgressIndicator(Modifier.size(22.dp), color = Palette.brand, strokeWidth = 2.dp)
        else Icon(
            if (done) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
            "Marquer « ${reminder.label} » comme fait",
            tint = if (done) Palette.success else Palette.pendingRing,
            modifier = Modifier.size(26.dp).clickable(enabled = !done, role = Role.Button, onClick = onComplete),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(reminder.label, style = Type.body.copy(textDecoration = if (done) TextDecoration.LineThrough else null), color = Palette.textPrimary)
            Text(Reminder.dueLabel(reminder.dueAt), style = Type.secondary,
                color = if (reminder.isOverdue()) Palette.staleText else Palette.textSecondary)
        }
    }
}
