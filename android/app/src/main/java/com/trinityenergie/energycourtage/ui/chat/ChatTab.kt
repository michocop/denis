package com.trinityenergie.energycourtage.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.ConfirmationNumber
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Unarchive
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.data.ChatRepository
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.admin
import com.trinityenergie.energycourtage.data.chat
import com.trinityenergie.energycourtage.model.ChatThread
import com.trinityenergie.energycourtage.model.MemberOverview
import com.trinityenergie.energycourtage.ui.components.Avatar
import com.trinityenergie.energycourtage.ui.components.EmptyState
import com.trinityenergie.energycourtage.ui.components.FieldBox
import com.trinityenergie.energycourtage.ui.components.FullScreenSheet
import com.trinityenergie.energycourtage.ui.components.LabelledField
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.PrimaryActionButton
import com.trinityenergie.energycourtage.ui.components.ScreenTitle
import com.trinityenergie.energycourtage.ui.components.SearchField
import com.trinityenergie.energycourtage.ui.components.SegmentedPicker
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch

/**
 * Chat: discussions and tickets (Features/Chat/ChatView.swift). Pin and
 * archive by swipe, applied at once and put back if the server refuses.
 *
 * [openThreadId] is a conversation to open now -- a tapped notification; once
 * it is open (or found not to exist) [onRouteConsumed] is called.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatTab(deps: Dependencies, openThreadId: String?, onRouteConsumed: () -> Unit) {
    val repository = remember(deps) { deps.chat() }
    val admin = remember(deps) { deps.admin() }
    val scope = rememberCoroutineScope()

    var threads by remember { mutableStateOf<List<ChatThread>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var segment by remember { mutableStateOf(ChatSegment.Discussions) }
    var filter by remember { mutableStateOf(ChatFilter.All) }
    var query by remember { mutableStateOf("") }

    // Who "me" is, to tell my bubbles from theirs: the profile's id, as on iOS.
    var me by remember { mutableStateOf<String?>(null) }
    var isAdmin by remember { mutableStateOf(deps.role.isAdmin) }
    var contacts by remember { mutableStateOf<List<MemberOverview>?>(null) }
    var contactsError by remember { mutableStateOf<String?>(null) }

    var open by remember { mutableStateOf<ChatThread?>(null) }
    var showsContacts by remember { mutableStateOf(false) }
    var showsTicket by remember { mutableStateOf(false) }
    var starting by remember { mutableStateOf(false) }

    suspend fun load() {
        try {
            if (me == null) {
                // a profile that fails to load must not hide the list: the
                // session's own id is the same one (current_profile_id = auth.uid())
                runCatching { deps.profiles.currentProfile() }.getOrNull()?.let { profile ->
                    me = profile.id
                    isAdmin = profile.role.isAdmin
                }
            }
            threads = repository.loadThreads()
            error = null
        } catch (e: Exception) {
            error = e.message
        }
        loaded = true
    }

    suspend fun loadContacts() {
        if (!isAdmin || contacts != null) return
        try {
            contacts = admin.members().filter { it.isActive }
            contactsError = null
        } catch (e: Exception) {
            contactsError = e.message
        }
    }

    /** An apporteur has exactly one person to write to and is not asked to
     *  pick; an admin picks from the members list. */
    suspend fun startConversation(contact: MemberOverview?): ChatThread? {
        starting = true
        return try {
            val id = if (contact != null) repository.startDirectThread(contact.id) else repository.startSupportThread()
            threads = repository.loadThreads()
            error = null
            threads.firstOrNull { it.id == id }
        } catch (e: Exception) {
            error = e.message; null
        } finally {
            starting = false
        }
    }

    fun applyFlags(thread: ChatThread, pinned: Boolean?, archived: Boolean?) {
        val previous = threads.firstOrNull { it.id == thread.id } ?: return
        val changed = previous.copy(pinned = pinned ?: previous.pinned, archived = archived ?: previous.archived)
        threads = threads.map { if (it.id == thread.id) changed else it }
        scope.launch {
            try {
                repository.setFlags(thread.id, pinned, archived)
            } catch (e: Exception) {
                threads = threads.map { if (it.id == thread.id) previous else it }
                error = e.message
            }
        }
    }

    LaunchedEffect(repository) {
        load()
        loadContacts()
    }
    // the selected chip has to be one the segment shows
    LaunchedEffect(segment) {
        if (filter !in ChatRules.availableFilters(segment)) filter = ChatFilter.All
    }
    // a notification about a message opens its conversation
    LaunchedEffect(openThreadId) {
        val id = openThreadId ?: return@LaunchedEffect
        if (threads.none { it.id == id }) load()
        threads.firstOrNull { it.id == id }?.let { open = it }
        onRouteConsumed()
    }

    val visible = ChatRules.visibleThreads(threads, segment, filter, query)

    BrandBackground {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = Spacing.gutter),
            verticalArrangement = Arrangement.spacedBy(Spacing.l),
        ) {
            ScreenTitle("Chat")
            SegmentedPicker(segment, listOf(ChatSegment.Discussions to "Discussions", ChatSegment.Tickets to "Tickets"), { segment = it })

            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalAlignment = Alignment.CenterVertically) {
                SearchField(
                    if (segment == ChatSegment.Tickets) "Rechercher un ticket" else "Rechercher une discussion",
                    query, { query = it }, Modifier.weight(1f),
                )
                Box(
                    Modifier.size(52.dp).cardSurface(Radius.field)
                        .clickable(enabled = !starting) {
                            when {
                                segment == ChatSegment.Tickets -> showsTicket = true
                                isAdmin -> { showsContacts = true; scope.launch { loadContacts() } }
                                else -> scope.launch { startConversation(null)?.let { open = it } }
                            }
                        }
                        .semantics { contentDescription = "Nouvelle discussion" },
                    contentAlignment = Alignment.Center,
                ) {
                    if (starting) CircularProgressIndicator(color = Palette.brand, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                    else Icon(Icons.Outlined.EditNote, null, tint = Palette.brand, modifier = Modifier.size(24.dp))
                }
            }

            FilterChips(ChatRules.availableFilters(segment), if (filter in ChatRules.availableFilters(segment)) filter else ChatFilter.All) { filter = it }

            error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }

            PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } },
                modifier = Modifier.fillMaxWidth().weight(1f),
            ) {
                LazyColumn(Modifier.fillMaxSize()) {
                    when {
                        !loaded -> item { LoadingBlock() }
                        visible.isEmpty() -> item {
                            EmptyState(
                                if (segment == ChatSegment.Tickets) Icons.Outlined.ConfirmationNumber else Icons.Outlined.Forum,
                                if (segment == ChatSegment.Tickets) "Aucun ticket" else "Aucune discussion",
                            )
                        }
                        else -> items(visible, key = { it.id }) { thread ->
                            SwipeableThreadRow(
                                thread,
                                onOpen = { open = thread },
                                onTogglePin = { applyFlags(thread, pinned = !thread.pinned, archived = null) },
                                onToggleArchive = { applyFlags(thread, pinned = null, archived = !thread.archived) },
                            )
                            HorizontalDivider(color = Palette.hairline)
                        }
                    }
                }
            }
        }
    }

    open?.let { thread ->
        ThreadScreen(
            thread = thread,
            me = me ?: deps.myId,
            repository = repository,
            onDismiss = { open = null; scope.launch { load() } },
        )
    }

    if (showsContacts) {
        ContactPicker(
            contacts = contacts,
            error = contactsError,
            onPick = { contact ->
                showsContacts = false
                scope.launch { startConversation(contact)?.let { open = it } }
            },
            onDismiss = { showsContacts = false },
        )
    }

    if (showsTicket) {
        TicketComposer(
            repository = repository,
            onOpened = { id ->
                showsTicket = false
                scope.launch {
                    load()
                    threads.firstOrNull { it.id == id }?.let { open = it }
                }
            },
            onDismiss = { showsTicket = false },
        )
    }
}

@Composable
private fun FilterChips(filters: List<ChatFilter>, selected: ChatFilter, onSelect: (ChatFilter) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        filters.forEach { f ->
            val isSelected = f == selected
            val shape = RoundedCornerShape(Radius.button)
            Text(
                f.label,
                style = Type.body,
                color = if (isSelected) Color.White else Palette.textPrimary,
                modifier = Modifier
                    .background(if (isSelected) Palette.brandFill else Palette.surface, shape)
                    .border(1.dp, if (isSelected) Color.Transparent else Palette.hairline, shape)
                    .clickable { onSelect(f) }
                    .semantics { this.selected = isSelected }
                    .padding(horizontal = Spacing.xl, vertical = 10.dp),
            )
        }
    }
}

/** Swipe right to pin, left to archive -- the row springs back and the change
 *  applies, as iOS's swipe actions do. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableThreadRow(thread: ChatThread, onOpen: () -> Unit, onTogglePin: () -> Unit, onToggleArchive: () -> Unit) {
    // the state keeps the first lambdas it was given: read the current ones
    val pin by rememberUpdatedState(onTogglePin)
    val archive by rememberUpdatedState(onToggleArchive)
    // one swipe, one change: the state may ask more than once per gesture
    var lastAction by remember { mutableStateOf(0L) }
    val state = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            val now = System.currentTimeMillis()
            if (value != SwipeToDismissBoxValue.Settled && now - lastAction > 600) {
                lastAction = now
                if (value == SwipeToDismissBoxValue.StartToEnd) pin() else archive()
            }
            false
        },
        positionalThreshold = { it * 0.3f },
    )
    SwipeToDismissBox(
        state = state,
        backgroundContent = {
            val direction = state.dismissDirection
            val (label, icon, tint) = when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> Triple(
                    if (thread.pinned) "Détacher" else "Épingler",
                    Icons.Outlined.PushPin, Palette.brandFill,
                )
                SwipeToDismissBoxValue.EndToStart -> Triple(
                    if (thread.archived) "Désarchiver" else "Archiver",
                    if (thread.archived) Icons.Outlined.Unarchive else Icons.Outlined.Archive, Palette.textSecondary,
                )
                SwipeToDismissBoxValue.Settled -> Triple("", null, Color.Transparent)
            }
            Box(
                Modifier.fillMaxSize().background(tint, RoundedCornerShape(Spacing.l)).padding(horizontal = Spacing.xl),
                contentAlignment = if (direction == SwipeToDismissBoxValue.EndToStart) Alignment.CenterEnd else Alignment.CenterStart,
            ) {
                if (icon != null) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        Icon(icon, null, tint = Color.White, modifier = Modifier.size(20.dp))
                        Text(label, style = Type.label, color = Color.White)
                    }
                }
            }
        },
    ) {
        // opaque only while it is being swiped, to hide the action behind it;
        // at rest the brand background shows through like everywhere else
        ThreadRow(thread, Modifier
            .background(if (state.dismissDirection != SwipeToDismissBoxValue.Settled) Palette.night else Color.Transparent)
            .clickable(onClick = onOpen))
    }
}

@Composable
private fun ThreadRow(thread: ChatThread, modifier: Modifier = Modifier) {
    val description = buildList {
        add(thread.displayName); add(thread.lastMessage ?: "Aucun message")
        if (thread.unreadCount > 0) add("${thread.unreadCount} non lus")
    }.joinToString(", ")
    Row(
        modifier.fillMaxWidth().padding(vertical = Spacing.m).semantics(mergeDescendants = true) { contentDescription = description },
        horizontalArrangement = Arrangement.spacedBy(Spacing.l),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(thread.displayName, 56.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(thread.displayName, style = Type.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (thread.pinned) Icon(Icons.Filled.PushPin, null, tint = Palette.textSecondary, modifier = Modifier.size(13.dp))
            }
            Text(thread.lastMessage ?: "Aucun message", style = Type.secondary, color = Palette.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            thread.lastMessageAt?.let { Text(Dates.time(it), style = Type.caption, color = Palette.textSecondary) }
            if (thread.unreadCount > 0) {
                Text("${thread.unreadCount}", style = Type.caption, color = Color.White,
                    modifier = Modifier.background(Palette.brandFill, CircleShape).padding(horizontal = 8.dp, vertical = 3.dp))
            }
        }
    }
}

/** The admin's "Nouvelle discussion": an active member to write to. */
@Composable
private fun ContactPicker(contacts: List<MemberOverview>?, error: String?, onPick: (MemberOverview) -> Unit, onDismiss: () -> Unit) {
    FullScreenSheet("Nouvelle discussion", onDismiss, scrolls = false) {
        when {
            contacts == null && error != null -> Text(error, style = Type.secondary, color = Palette.destructive)
            contacts == null -> LoadingBlock()
            contacts.isEmpty() -> EmptyState(Icons.Outlined.Forum, "Aucun apporteur actif")
            else -> LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                items(contacts, key = { it.id }) { contact ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onPick(contact) }.padding(vertical = Spacing.m),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
                    ) {
                        Avatar(contact.fullName)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(contact.fullName, style = Type.body, color = Palette.textPrimary)
                            Text(contact.email, style = Type.secondary, color = Palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.textSecondary)
                    }
                    HorizontalDivider(color = Palette.hairline)
                }
            }
        }
    }
}

/** "Nouveau ticket": a tracked request with a subject (open_ticket). Kept
 *  open until the server answers, so a failure leaves the text where it was. */
@Composable
private fun TicketComposer(repository: ChatRepository, onOpened: (String) -> Unit, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var subject by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    FullScreenSheet("Nouveau ticket", onDismiss = { if (!working) onDismiss() }) {
        LabelledField("Sujet", subject, { subject = it }, placeholder = "Problème de virement")
        MultilineField("Description", body, { body = it })
        Text("Un administrateur est affecté au ticket dès son ouverture.", style = Type.secondary, color = Palette.textSecondary)
        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }
        PrimaryActionButton(
            "Ouvrir le ticket",
            enabled = subject.isNotBlank() && body.isNotBlank(),
            working = working,
        ) {
            working = true
            scope.launch {
                try {
                    val id = repository.openTicket(subject.trim(), body.trim())
                    onOpened(id)
                } catch (e: Exception) {
                    error = e.message
                } finally {
                    working = false
                }
            }
        }
        Spacer(Modifier.size(Spacing.s))
    }
}

/** A labelled field for a few lines of text (iOS TextEditor). */
@Composable
internal fun MultilineField(label: String, value: String, onValueChange: (String) -> Unit, placeholder: String = "") {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(label, style = Type.caption, color = Palette.textSecondary, modifier = Modifier.padding(start = 4.dp))
        FieldBox {
            BasicTextField(
                value, onValueChange,
                textStyle = Type.body.copy(color = Palette.textPrimary),
                cursorBrush = SolidColor(Palette.brand),
                modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
                decorationBox = { inner ->
                    if (value.isEmpty() && placeholder.isNotEmpty()) Text(placeholder, style = Type.body, color = Palette.textSecondary.copy(alpha = 0.6f))
                    inner()
                },
            )
        }
    }
}
