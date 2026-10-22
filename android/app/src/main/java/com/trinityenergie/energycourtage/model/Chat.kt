package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant

@Serializable
enum class ThreadKind { @SerialName("direct") Direct, @SerialName("group") Group, @SerialName("ticket") Ticket }

/** A row of `thread_overview` (iOS ChatThread): the view names a direct
 *  conversation after the other person and carries the last message and this
 *  reader's unread count, pin and archive. */
@Serializable
data class ChatThread(
    val id: String,
    val kind: ThreadKind = ThreadKind.Direct,
    val title: String? = null,
    val counterpartName: String = "",
    val lastMessage: String? = null,
    @Serializable(InstantSerializer::class) val lastMessageAt: Instant? = null,
    val unreadCount: Int = 0,
    val pinned: Boolean = false,
    val archived: Boolean = false,
) {
    val displayName: String get() = title ?: counterpartName
    val initials: String
        get() = displayName.split(" ").filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1) }.uppercase()
}

/** A row of `message_feed`; the INSERT into `messages` returns the same shape
 *  without the sender's name. */
@Serializable
data class ChatMessage(
    val id: String,
    val threadId: String,
    val senderId: String,
    val senderName: String? = null,
    val body: String? = null,
    @Serializable(InstantSerializer::class) val createdAt: Instant,
)
