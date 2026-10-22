package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.core.SupabaseException
import com.trinityenergie.energycourtage.model.ChatMessage
import com.trinityenergie.energycourtage.model.ChatThread
import com.trinityenergie.energycourtage.model.ThreadKind
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.UUID

/** iOS ChatRepository (Core/Repositories.swift). */
interface ChatRepository {
    suspend fun loadThreads(): List<ChatThread>
    suspend fun loadMessages(threadId: String): List<ChatMessage>
    suspend fun send(body: String, threadId: String): ChatMessage
    suspend fun markRead(threadId: String)
    suspend fun openTicket(subject: String, body: String): String
    /** The thread id, created only if it does not exist yet: the apporteur
     *  does not know which administrator to write to. */
    suspend fun startSupportThread(): String
    suspend fun startDirectThread(profileId: String): String
    /** Pinning and archiving are per reader, not per thread. */
    suspend fun setFlags(threadId: String, pinned: Boolean?, archived: Boolean?)
}

fun Dependencies.chat(): ChatRepository = if (isDemo) DemoChatRepository(myId) else SupabaseChatRepository(requireClient())

class SupabaseChatRepository(private val client: SupabaseClient) : ChatRepository {

    /** `thread_overview`, not `threads`: the raw table has no name on a direct
     *  conversation, no last message and no unread count. */
    override suspend fun loadThreads(): List<ChatThread> =
        client.decode(client.select("thread_overview", "order=last_message_at.desc.nullslast"))

    override suspend fun loadMessages(threadId: String): List<ChatMessage> =
        client.decode(client.select("message_feed", "thread_id=eq.$threadId&order=created_at.asc,id.asc"))

    /** The INSERT returns the messages row, which carries no sender name; the
     *  composer labels its own bubble "Vous" anyway. */
    override suspend fun send(body: String, threadId: String): ChatMessage {
        val sender = client.userId ?: currentProfileId()
        val rows = client.insert("messages", buildJsonObject {
            put("thread_id", threadId)
            put("sender_id", sender)
            put("body", body)
        }).jsonArray
        val row = rows.firstOrNull() ?: throw SupabaseException.Decoding("no message returned")
        return client.decode(row)
    }

    private suspend fun currentProfileId(): String =
        runCatching { client.rpc("current_profile_id").jsonPrimitive.content }.getOrNull()
            ?.takeIf { it != "null" } ?: throw SupabaseException.Unauthenticated()

    override suspend fun markRead(threadId: String) =
        client.rpcVoid("mark_thread_read", buildJsonObject { put("p_thread_id", threadId) })

    override suspend fun openTicket(subject: String, body: String): String =
        client.rpc("open_ticket", buildJsonObject { put("p_subject", subject); put("p_body", body) }).jsonPrimitive.content

    override suspend fun startSupportThread(): String = client.rpc("start_support_thread").jsonPrimitive.content

    override suspend fun startDirectThread(profileId: String): String =
        client.rpc("start_direct_thread", buildJsonObject { put("p_other_profile_id", profileId) }).jsonPrimitive.content

    override suspend fun setFlags(threadId: String, pinned: Boolean?, archived: Boolean?) =
        client.rpcVoid("set_thread_flags", buildJsonObject {
            put("p_thread_id", threadId)
            if (pinned != null) put("p_pinned", pinned)
            if (archived != null) put("p_archived", archived)
        })
}

/**
 * The demo's conversations (iOS DemoChatStore), kept for the session so what
 * is sent, pinned or archived stays that way across screens.
 */
object DemoChatStore {
    const val supportThread = "aaaaaaaa-0000-0000-0000-000000000001"
    const val marieThread = "aaaaaaaa-0000-0000-0000-000000000002"
    const val ticketThread = "aaaaaaaa-0000-0000-0000-000000000003"

    private val mutex = Mutex()
    private var threads = mutableListOf<ChatThread>()
    private val messages = mutableMapOf<String, MutableList<ChatMessage>>()

    init { reset() }

    fun reset() {
        val now = Instant.now()
        threads = mutableListOf(
            ChatThread(supportThread, ThreadKind.Direct, counterpartName = "Pierre-Louis Tettamanti",
                lastMessage = "Je vous réponds tout de suite.", lastMessageAt = now.minusSeconds(600), unreadCount = 1),
            ChatThread(marieThread, ThreadKind.Direct, counterpartName = "Marie Durand",
                lastMessage = "Merci !", lastMessageAt = now.minusSeconds(7200), pinned = true),
            ChatThread(ticketThread, ThreadKind.Ticket, title = "Problème de virement", counterpartName = "Support",
                lastMessage = "Je n'ai pas reçu mon paiement.", lastMessageAt = now.minusSeconds(86_400)),
        )
        messages.clear()
        messages[supportThread] = mutableListOf(
            ChatMessage(uuid(), supportThread, Demo.me, "Johann Lefeuvre", "Bonjour, une question sur Thomas Dubois.", now.minusSeconds(900)),
            ChatMessage(uuid(), supportThread, Demo.them, "Pierre-Louis Tettamanti", "Je vous réponds tout de suite.", now.minusSeconds(600)),
        )
        messages[marieThread] = mutableListOf(
            ChatMessage(uuid(), marieThread, Demo.me, "Johann Lefeuvre", "C'est signé pour Boulangerie Petit.", now.minusSeconds(7400)),
            ChatMessage(uuid(), marieThread, uuid(), "Marie Durand", "Merci !", now.minusSeconds(7200)),
        )
        messages[ticketThread] = mutableListOf(
            ChatMessage(uuid(), ticketThread, Demo.me, "Johann Lefeuvre", "Je n'ai pas reçu mon paiement.", now.minusSeconds(86_400)),
        )
    }

    private fun uuid() = UUID.randomUUID().toString()
    private fun nameOf(id: String) = if (id == Demo.them) "Pierre-Louis Tettamanti" else "Johann Lefeuvre"

    /** A direct conversation is named after the other person, so the name
     *  depends on who is reading: the admin demo must not see a thread
     *  labelled with the admin's own name. */
    suspend fun threads(viewer: String): List<ChatThread> = mutex.withLock {
        threads.map { if (viewer == Demo.them && it.id == supportThread) it.copy(counterpartName = "Johann Lefeuvre") else it }
    }

    suspend fun messages(threadId: String): List<ChatMessage> = mutex.withLock { messages[threadId]?.toList() ?: emptyList() }

    suspend fun send(body: String, threadId: String, sender: String): ChatMessage = mutex.withLock {
        val message = ChatMessage(uuid(), threadId, sender, nameOf(sender), body, Instant.now())
        messages.getOrPut(threadId) { mutableListOf() }.add(message)
        update(threadId) { it.copy(lastMessage = body, lastMessageAt = message.createdAt) }
        message
    }

    suspend fun markRead(threadId: String) = mutex.withLock { update(threadId) { it.copy(unreadCount = 0) } }

    suspend fun setFlags(threadId: String, pinned: Boolean?, archived: Boolean?) = mutex.withLock {
        update(threadId) { it.copy(pinned = pinned ?: it.pinned, archived = archived ?: it.archived) }
    }

    suspend fun openTicket(subject: String, body: String, sender: String): String = mutex.withLock {
        val id = uuid()
        val now = Instant.now()
        threads.add(ChatThread(id, ThreadKind.Ticket, title = subject, counterpartName = "Support",
            lastMessage = body, lastMessageAt = now))
        messages[id] = mutableListOf(ChatMessage(uuid(), id, sender, nameOf(sender), body, now))
        id
    }

    fun startSupport(): String = supportThread

    /** Johann is the demo admin's support conversation; anyone else gets a new
     *  direct thread named after them. */
    suspend fun startDirect(profileId: String, name: String?): String = mutex.withLock {
        if (profileId == Demo.me) return@withLock supportThread
        threads.firstOrNull { it.id == profileId }?.id ?: run {
            threads.add(ChatThread(profileId, ThreadKind.Direct, counterpartName = name ?: "Nouvelle discussion"))
            profileId
        }
    }

    private fun update(id: String, change: (ChatThread) -> ChatThread) {
        val i = threads.indexOfFirst { it.id == id }
        if (i >= 0) threads[i] = change(threads[i])
    }
}

/** The viewer decides how a direct conversation is named, so the demo
 *  repository is told which side of it the app is showing. */
class DemoChatRepository(private val viewer: String) : ChatRepository {
    override suspend fun loadThreads(): List<ChatThread> { delay(80); return DemoChatStore.threads(viewer) }
    override suspend fun loadMessages(threadId: String) = DemoChatStore.messages(threadId)
    override suspend fun send(body: String, threadId: String): ChatMessage { delay(150); return DemoChatStore.send(body, threadId, viewer) }
    override suspend fun markRead(threadId: String) = DemoChatStore.markRead(threadId)
    override suspend fun openTicket(subject: String, body: String) = DemoChatStore.openTicket(subject, body, viewer)
    override suspend fun startSupportThread() = DemoChatStore.startSupport()
    override suspend fun startDirectThread(profileId: String) =
        DemoChatStore.startDirect(profileId, DemoAdminStore.memberName(profileId))
    override suspend fun setFlags(threadId: String, pinned: Boolean?, archived: Boolean?) =
        DemoChatStore.setFlags(threadId, pinned, archived)
}
