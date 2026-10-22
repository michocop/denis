package com.trinityenergie.energycourtage.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.data.ChatRepository
import com.trinityenergie.energycourtage.model.ChatMessage
import com.trinityenergie.energycourtage.model.ChatThread
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

private const val PENDING = "pending-"

/**
 * One conversation (Features/Chat/ThreadDetailView.swift). Read on opening,
 * then polled every five seconds while on screen -- right for an apporteur
 * and their account manager exchanging a few messages a day. A poll only
 * appends what is new; sending is optimistic and handed back to the composer
 * if it fails.
 */
@Composable
internal fun ThreadScreen(thread: ChatThread, me: String, repository: ChatRepository, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var messages by remember(thread.id) { mutableStateOf<List<ChatMessage>>(emptyList()) }
    var loaded by remember(thread.id) { mutableStateOf(false) }
    var error by remember(thread.id) { mutableStateOf<String?>(null) }
    var draft by remember(thread.id) { mutableStateOf("") }
    val listState = rememberLazyListState()

    LaunchedEffect(thread.id) {
        try {
            messages = repository.loadMessages(thread.id)
            runCatching { repository.markRead(thread.id) }
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        loaded = true
        while (isActive) {
            delay(5_000)
            val fresh = runCatching { repository.loadMessages(thread.id) }.getOrNull() ?: continue
            val arrived = ChatRules.arrived(messages, fresh)
            if (arrived.isEmpty()) continue
            messages = messages + arrived
            runCatching { repository.markRead(thread.id) }
        }
    }

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.lastIndex)
    }

    fun send() {
        val body = draft.trim()
        if (body.isEmpty()) return
        draft = ""
        val pending = ChatMessage(PENDING + UUID.randomUUID(), thread.id, me, "", body, Instant.now())
        messages = messages + pending
        scope.launch {
            try {
                val saved = repository.send(body, thread.id)
                // a poll may have brought it in already
                messages = if (messages.any { it.id == saved.id }) messages.filter { it.id != pending.id }
                else messages.map { if (it.id == pending.id) saved else it }
                error = null
            } catch (e: Exception) {
                messages = messages.filter { it.id != pending.id }
                draft = body
                error = e.message
            }
        }
    }

    FullScreenSheet(thread.displayName, onDismiss, back = true, scrolls = false) {
        Box(Modifier.fillMaxWidth().weight(1f)) {
            when {
                !loaded -> LoadingBlock()
                messages.isEmpty() -> Text("Aucun message", style = Type.secondary, color = Palette.textSecondary,
                    modifier = Modifier.align(Alignment.Center))
                else -> LazyColumn(
                    Modifier.fillMaxWidth(),
                    state = listState,
                    verticalArrangement = Arrangement.spacedBy(Spacing.s),
                ) {
                    items(messages, key = { it.id }) { MessageBubble(it, isMine = it.senderId == me) }
                }
            }
        }
        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
        Composer(draft, { draft = it }, ::send)
    }
}

@Composable
private fun Composer(draft: String, onChange: (String) -> Unit, onSend: () -> Unit) {
    val canSend = draft.isNotBlank()
    Row(
        Modifier.fillMaxWidth().padding(bottom = Spacing.m),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Box(
            Modifier.weight(1f).background(Palette.track, RoundedCornerShape(20.dp)).padding(horizontal = Spacing.l, vertical = 12.dp),
        ) {
            if (draft.isEmpty()) Text("Message", style = Type.body, color = Palette.textSecondary)
            BasicTextField(
                draft, onChange,
                textStyle = Type.body.copy(color = Palette.textPrimary),
                cursorBrush = SolidColor(Palette.brand),
                maxLines = 5,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Box(
            Modifier.size(44.dp)
                .background(if (canSend) Palette.brandFill else Palette.pendingRing, CircleShape)
                .clickable(enabled = canSend, role = Role.Button, onClick = onSend)
                .semantics { contentDescription = "Envoyer" },
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.ArrowUpward, null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessage, isMine: Boolean) {
    val label = "${if (isMine) "Vous" else message.senderName.orEmpty()}, ${message.body.orEmpty()}"
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = label }) {
        if (isMine) Spacer(Modifier.weight(1f).widthIn(min = 56.dp))
        Column(
            Modifier
                .widthIn(max = 300.dp)
                .alpha(if (message.id.startsWith(PENDING)) 0.7f else 1f)
                .background(if (isMine) Palette.brandFill else Palette.track, RoundedCornerShape(18.dp))
                .padding(horizontal = Spacing.l, vertical = 10.dp),
            horizontalAlignment = if (isMine) Alignment.End else Alignment.Start,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(message.body.orEmpty(), style = Type.body, color = if (isMine) Color.White else Palette.textPrimary)
            Text(Dates.time(message.createdAt), style = Type.caption.copy(fontSize = 11.sp),
                color = if (isMine) Color.White.copy(alpha = 0.75f) else Palette.textSecondary)
        }
        if (!isMine) Spacer(Modifier.weight(1f).widthIn(min = 56.dp))
    }
}
