package com.trinityenergie.energycourtage.ui.admin

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.data.RecommendationsRepository
import com.trinityenergie.energycourtage.model.AppointmentAgenda
import com.trinityenergie.energycourtage.model.RecoDates
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.ui.components.EmptyState
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.ScreenTitle
import com.trinityenergie.energycourtage.ui.recommendations.AppointmentSheet
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch

/** Every meeting fixed, the next one first (Features/Admin/AppointmentsView.swift). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppointmentsScreen(repository: RecommendationsRepository, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var meetings by remember { mutableStateOf<List<Recommendation>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<Recommendation?>(null) }

    suspend fun load() {
        try {
            meetings = repository.appointments()
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        loaded = true
    }

    LaunchedEffect(repository) { load() }

    FullScreenSheet("", onDismiss, back = true, scrolls = false) {
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } },
            modifier = Modifier.fillMaxWidth().weight(1f),
        ) {
            val agenda = AppointmentAgenda.of(meetings)
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                item { ScreenTitle("Rendez-vous") }
                error?.let { message -> item { Text(message, style = Type.secondary, color = Palette.destructive) } }
                when {
                    !loaded -> item { LoadingBlock() }
                    meetings.isEmpty() && error == null -> item { EmptyState(Icons.Outlined.Event, "Aucun rendez-vous fixé.") }
                }
                if (agenda.upcoming.isNotEmpty()) {
                    item { SectionTitle("À venir") }
                    items(agenda.upcoming, key = { it.id }) { MeetingRow(it) { editing = it } }
                }
                if (agenda.past.isNotEmpty()) {
                    item { SectionTitle("Passés") }
                    items(agenda.past, key = { it.id }) { MeetingRow(it) { editing = it } }
                }
            }
        }
    }

    editing?.let { meeting ->
        AppointmentSheet(
            recommendation = meeting,
            save = { at -> repository.setAppointment(meeting.id, at); load() },
            onDismiss = { editing = null },
        )
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(title, style = Type.caption, color = Palette.textSecondary, modifier = Modifier.padding(start = 4.dp, top = Spacing.s))
}

@Composable
private fun MeetingRow(meeting: Recommendation, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().cardSurface().clickable(role = Role.Button, onClick = onClick).padding(Spacing.l),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(meeting.appointmentAt?.let { RecoDates.appointment(it) }?.replaceFirstChar(Char::uppercase) ?: "",
                style = Type.label, color = Palette.textPrimary)
            Text(meeting.filleulName, style = Type.body, color = Palette.textPrimary)
            meeting.filleulPhone?.let { Text(it, style = Type.secondary, color = Palette.textSecondary) }
            Text("Recommandé par ${meeting.parrainName}", style = Type.caption, color = Palette.textSecondary)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.textSecondary, modifier = Modifier.size(18.dp))
    }
}
