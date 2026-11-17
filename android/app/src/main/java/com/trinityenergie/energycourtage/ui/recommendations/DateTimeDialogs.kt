package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.ui.components.FieldBox
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset

/** The picker allows nothing before now, as iOS's `in: Date.now...`. */
internal fun clampFuture(i: Instant): Instant = if (i.isBefore(Instant.now())) Instant.now().plusSeconds(60) else i

/** The day of [value], keeping its time. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FutureDateDialog(value: Instant, onPick: (Instant) -> Unit, onDismiss: () -> Unit) {
    val zone = ZoneId.systemDefault()
    val today = LocalDate.now(zone)
    val state = rememberDatePickerState(
        initialSelectedDateMillis = value.atZone(zone).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        selectableDates = object : SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long) =
                !Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate().isBefore(today)
            override fun isSelectableYear(year: Int) = year >= today.year
        },
    )
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton({
                state.selectedDateMillis?.let { millis ->
                    val day = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
                    val time = value.atZone(zone).toLocalTime()
                    onPick(clampFuture(day.atTime(time).atZone(zone).toInstant()))
                }
                onDismiss()
            }) { Text("OK", style = Type.label, color = Palette.brand) }
        },
        dismissButton = { TextButton(onDismiss) { Text("Annuler", style = Type.label, color = Palette.textSecondary) } },
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

/** The time of [value], keeping its day. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FutureTimeDialog(title: String, value: Instant, onPick: (Instant) -> Unit, onDismiss: () -> Unit) {
    val zone = ZoneId.systemDefault()
    val current = value.atZone(zone)
    val state = rememberTimePickerState(current.hour, current.minute, is24Hour = true)
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier.background(Palette.surface, RoundedCornerShape(Radius.modal)).padding(Spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Spacing.l),
        ) {
            Text(title, style = Type.label, color = Palette.textSecondary, modifier = Modifier.fillMaxWidth())
            TimePicker(state, colors = TimePickerDefaults.colors(
                clockDialColor = Palette.track,
                selectorColor = Palette.brandFill,
                timeSelectorSelectedContainerColor = Palette.brandSoft,
                timeSelectorSelectedContentColor = Palette.textPrimary,
                timeSelectorUnselectedContainerColor = Palette.track,
                timeSelectorUnselectedContentColor = Palette.textSecondary,
            ))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onDismiss) { Text("Annuler", style = Type.label, color = Palette.textSecondary) }
                TextButton({
                    val day = value.atZone(zone).toLocalDate()
                    onPick(clampFuture(day.atTime(LocalTime.of(state.hour, state.minute)).atZone(zone).toInstant()))
                    onDismiss()
                }) { Text("OK", style = Type.label, color = Palette.brand) }
            }
        }
    }
}

/** The day and the hour of a meeting, each opening its picker. */
@Composable
internal fun AppointmentFields(value: Instant, onChange: (Instant) -> Unit) {
    var pickingDate by remember { mutableStateOf(false) }
    var pickingTime by remember { mutableStateOf(false) }
    val zoned = value.atZone(ZoneId.systemDefault())
    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        FieldBox(Modifier.weight(1.4f).clickable(role = Role.Button) { pickingDate = true }
            .semantics { contentDescription = "Date du rendez-vous" }) {
            Text(Dates.medium(value), style = Type.body, color = Palette.textPrimary)
        }
        FieldBox(Modifier.weight(1f).clickable(role = Role.Button) { pickingTime = true }
            .semantics { contentDescription = "Heure du rendez-vous" }) {
            Text("%02d:%02d".format(zoned.hour, zoned.minute), style = Type.body, color = Palette.textPrimary)
        }
    }
    if (pickingDate) FutureDateDialog(value, onChange) { pickingDate = false }
    if (pickingTime) FutureTimeDialog("Heure du rendez-vous", value, onChange) { pickingTime = false }
}
