package com.trinityenergie.energycourtage.ui.notifications

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Alarm
import androidx.compose.material.icons.outlined.ArrowCircleRight
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Draw
import androidx.compose.material.icons.outlined.EuroSymbol
import androidx.compose.material.icons.outlined.HighlightOff
import androidx.compose.material.icons.outlined.HowToReg
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Payments
import androidx.compose.material.icons.outlined.PersonAddAlt
import androidx.compose.material.icons.outlined.PersonSearch
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.NotificationsRepository
import com.trinityenergie.energycourtage.data.notifications
import com.trinityenergie.energycourtage.model.AppNotification
import com.trinityenergie.energycourtage.model.Route
import com.trinityenergie.energycourtage.ui.components.EmptyState
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import kotlinx.coroutines.launch
import java.time.Instant

/** The icon for each kind of notification (iOS AppNotification.icon). */
fun notificationIcon(kind: String): ImageVector = when (kind) {
    "stage_advanced" -> Icons.Outlined.ArrowCircleRight
    "reward_earned" -> Icons.Outlined.EuroSymbol
    "message_received" -> Icons.Outlined.ChatBubbleOutline
    "invoice_ready" -> Icons.Outlined.Description
    "payment_sent" -> Icons.Outlined.Payments
    "reminder_due" -> Icons.Outlined.Alarm
    "lead_created" -> Icons.Outlined.PersonAddAlt
    "member_pending" -> Icons.Outlined.PersonSearch
    "invoice_signed_by_apporteur" -> Icons.Outlined.Draw
    "document_added" -> Icons.Outlined.AttachFile
    "member_approved" -> Icons.Outlined.HowToReg
    "recommendation_lost" -> Icons.Outlined.HighlightOff
    "invoice_signed" -> Icons.Outlined.Verified
    else -> Icons.Outlined.Notifications
}

/**
 * The notifications list (Features/Notifications/NotificationsView.swift).
 * Opening it marks everything read: nothing is gained by making someone tap
 * each row to clear a badge. A tapped row hands its [Route] to [onOpen] --
 * the invoice, else the conversation, else the recommendation; the sheet does
 * not close itself, the caller decides.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotificationsSheet(deps: Dependencies, onOpen: (Route) -> Unit, onDismiss: () -> Unit) {
    val repository = remember(deps) { deps.notifications() }
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<AppNotification>>(emptyList()) }
    var unread by remember { mutableStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        try {
            items = repository.notifications()
            unread = repository.unreadCount()
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        loaded = true
    }

    LaunchedEffect(repository) {
        load()
        markRead(repository, unread, onDone = {
            unread = 0
            val now = Instant.now()
            items = items.map { if (it.readAt == null) it.copy(readAt = now) else it }
        }, onError = { error = it })
    }

    FullScreenSheet("Notifications", onDismiss, scrolls = false) {
        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } },
            modifier = Modifier.fillMaxWidth().weight(1f),
        ) {
            LazyColumn(Modifier.fillMaxSize()) {
                when {
                    !loaded -> item { LoadingBlock() }
                    items.isEmpty() -> item { EmptyState(Icons.Outlined.Notifications, "Aucune notification") }
                    else -> items(items, key = { it.id }) { item ->
                        NotificationRow(item, Modifier.clickable { item.route?.let(onOpen) })
                        HorizontalDivider(color = Palette.hairline)
                    }
                }
            }
        }
    }
}

private suspend fun markRead(repository: NotificationsRepository, unread: Int, onDone: () -> Unit, onError: (String?) -> Unit) {
    if (unread <= 0) return
    try {
        repository.markAllRead()
        onDone()
    } catch (e: Exception) {
        onError(e.message)
    }
}

@Composable
private fun NotificationRow(item: AppNotification, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().padding(vertical = Spacing.m).semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Spacing.l),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.size(34.dp).background(Palette.brand.copy(alpha = 0.12f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(notificationIcon(item.kind), null, tint = Palette.brand, modifier = Modifier.size(18.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(item.title, style = Type.body.copy(fontWeight = if (item.isUnread) FontWeight.SemiBold else FontWeight.Normal),
                color = Palette.textPrimary)
            if (item.body.isNotEmpty()) Text(item.body, style = Type.secondary, color = Palette.textSecondary)
            Text(Dates.relative(item.createdAt), style = Type.caption, color = Palette.textSecondary)
        }
    }
}
