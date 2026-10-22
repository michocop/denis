package com.trinityenergie.energycourtage.ui.chat

import com.trinityenergie.energycourtage.model.ChatMessage
import com.trinityenergie.energycourtage.model.ChatThread
import com.trinityenergie.energycourtage.model.ThreadKind
import java.time.Instant

/** The list's two segments (iOS ChatViewModel.Tab). */
enum class ChatSegment { Discussions, Tickets }

enum class ChatFilter(val label: String) {
    All("Toutes"), Unread("Non lues"), Groups("Groupes"), Pinned("Épinglées"), Archived("Archivées")
}

/** The filter and ordering rules of the list, kept apart from the screen so
 *  they can be tested: they are where the behaviour lives. */
object ChatRules {
    /** A ticket is never a group, so "Groupes" has nothing to show there. */
    fun availableFilters(segment: ChatSegment): List<ChatFilter> =
        if (segment == ChatSegment.Tickets) ChatFilter.entries.filter { it != ChatFilter.Groups } else ChatFilter.entries

    fun visibleThreads(threads: List<ChatThread>, segment: ChatSegment, filter: ChatFilter, query: String): List<ChatThread> {
        // "Groupes" chosen on Discussions, then Tickets opened, would leave the
        // ticket list empty: no ticket is a group.
        val effective = if (filter in availableFilters(segment)) filter else ChatFilter.All
        return threads.filter { t ->
            val matchesSegment = if (segment == ChatSegment.Tickets) t.kind == ThreadKind.Ticket else t.kind != ThreadKind.Ticket
            val matchesFilter = when (effective) {
                ChatFilter.All -> !t.archived
                ChatFilter.Unread -> t.unreadCount > 0 && !t.archived
                ChatFilter.Groups -> t.kind == ThreadKind.Group
                ChatFilter.Pinned -> t.pinned
                ChatFilter.Archived -> t.archived
            }
            val matchesQuery = query.isEmpty() || t.displayName.contains(query, ignoreCase = true)
            matchesSegment && matchesFilter && matchesQuery
        }
            // pinned first, then the most recent
            .sortedWith(compareByDescending<ChatThread> { it.pinned }.thenByDescending { it.lastMessageAt ?: Instant.MIN })
    }

    /** What a poll adds: only the messages not already shown, so a reply
     *  arriving mid-typing does not replace the list under the composer.
     *  Empty when nothing is new. */
    fun arrived(shown: List<ChatMessage>, fresh: List<ChatMessage>): List<ChatMessage> {
        if (fresh.size <= shown.size) return emptyList()
        val known = shown.mapTo(HashSet()) { it.id }
        return fresh.filter { it.id !in known }
    }
}
