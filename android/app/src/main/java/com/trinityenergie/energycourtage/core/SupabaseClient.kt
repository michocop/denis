package com.trinityenergie.energycourtage.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/** What can go wrong talking to Supabase, said in French as on iOS
 *  (`SupabaseError` in Core/SupabaseClient.swift). */
sealed class SupabaseException(message: String) : Exception(message) {
    class NotConfigured : SupabaseException("Configuration Supabase manquante (SUPABASE_URL / SUPABASE_ANON_KEY).")
    class Http(val status: Int, val serverMessage: String) : SupabaseException(
        when {
            (status == 401 || status == 403) && serverMessage.isEmpty() -> "Vous n'avez pas les droits pour cette action."
            status == 401 || status == 403 -> serverMessage
            serverMessage.isEmpty() -> "Erreur serveur ($status)."
            else -> serverMessage
        }
    )
    class Decoding(detail: String) : SupabaseException("Réponse inattendue du serveur. ($detail)")
    class Unauthenticated : SupabaseException("Session expirée, veuillez vous reconnecter.")
    class Offline : SupabaseException("Pas de connexion internet. Vérifiez votre réseau et réessayez.")
}

/** An emailed sign-in code that did not work. Auth answers in English and in
 *  its own shape, so the status decides -- the same mapping as iOS. */
class EmailCodeException(val kind: Kind) : Exception(kind.message) {
    enum class Kind(val message: String) {
        UnknownAddress("Aucun accès n'est ouvert pour cette adresse. Utilisez celle à laquelle Trinity Énergie vous a invité."),
        TooSoon("Un code vient d'être envoyé. Patientez une minute avant d'en demander un autre."),
        InvalidCode("Code incorrect ou expiré. Vérifiez le dernier e-mail reçu, ou demandez un nouveau code."),
        Unavailable("Le service est momentanément indisponible. Réessayez dans un instant."),
    }

    companion object {
        fun from(status: Int, verifying: Boolean) = EmailCodeException(
            when (status) {
                429 -> Kind.TooSoon
                401, 403 -> if (verifying) Kind.InvalidCode else Kind.Unavailable
                400, 404, 422 -> if (verifying) Kind.InvalidCode else Kind.UnknownAddress
                else -> Kind.Unavailable
            }
        )
    }
}

@Serializable
data class AuthUser(val id: String, val email: String? = null)

@Serializable
data class AuthSession(val accessToken: String, val refreshToken: String, val user: AuthUser)

/**
 * The app's only way to the backend: PostgREST, Auth, Storage and Edge
 * Functions over HTTPS, as the iPhone app's hand-written client does. Every
 * request carries the anon key; signed in, the access token too.
 *
 * A 401 refreshes the session once and retries. Supabase rotates refresh
 * tokens and treats a reused one as theft, so concurrent refreshes share one
 * in-flight call (the mutex), and the rotated token is handed to
 * [onRefreshTokenRotated] to be stored at once.
 */
class SupabaseClient(
    baseUrl: String,
    private val anonKey: String,
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build(),
) {
    private val base = baseUrl.trimEnd('/')
    private val refreshMutex = Mutex()

    @Volatile var accessToken: String? = null
    @Volatile var refreshToken: String? = null
    @Volatile var userId: String? = null
    var onRefreshTokenRotated: ((String?) -> Unit)? = null

    private val jsonType = "application/json".toMediaType()

    // ------------------------------------------------------------------ auth

    /** Emails a six-digit sign-in code, only to an address that already has
     *  an account: an invitation creates it, so this cannot open one. */
    suspend fun sendEmailCode(email: String) {
        val body = buildJsonObject { put("email", email); put("create_user", false) }
        try {
            raw("POST", "auth/v1/otp", body = body, allowRefresh = false)
        } catch (e: SupabaseException.Http) {
            throw EmailCodeException.from(e.status, verifying = false)
        }
    }

    suspend fun verifyEmailCode(code: String, email: String): AuthSession {
        val body = buildJsonObject { put("type", "email"); put("email", email); put("token", code) }
        val session = try {
            decode<AuthSession>(raw("POST", "auth/v1/verify", body = body, allowRefresh = false))
        } catch (e: SupabaseException.Http) {
            throw EmailCodeException.from(e.status, verifying = true)
        }
        adopt(session)
        return session
    }

    /** Signs back in from a stored refresh token. */
    suspend fun restore(refreshToken: String): AuthSession {
        val session = decode<AuthSession>(
            raw("POST", "auth/v1/token?grant_type=refresh_token",
                body = buildJsonObject { put("refresh_token", refreshToken) }, allowRefresh = false)
        )
        adopt(session)
        return session
    }

    fun clearSession() {
        accessToken = null; refreshToken = null; userId = null
    }

    private fun adopt(session: AuthSession) {
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        userId = session.user.id
        onRefreshTokenRotated?.invoke(session.refreshToken)
    }

    private suspend fun refreshOnce(staleAccessToken: String?): Boolean = refreshMutex.withLock {
        // someone else refreshed while we waited: their token is the new one
        if (accessToken != staleAccessToken && accessToken != null) return true
        val token = refreshToken ?: return false
        return try {
            restore(token); true
        } catch (e: SupabaseException.Http) {
            if (e.status in 400..499) { clearSession(); onRefreshTokenRotated?.invoke(null) }
            false
        }
    }

    // ------------------------------------------------------------ PostgREST

    suspend fun rpc(function: String, params: JsonObject = JsonObject(emptyMap())): JsonElement =
        parse(raw("POST", "rest/v1/rpc/$function", body = params))

    suspend fun rpcVoid(function: String, params: JsonObject = JsonObject(emptyMap())) {
        raw("POST", "rest/v1/rpc/$function", body = params, prefer = "return=minimal")
    }

    suspend fun select(table: String, query: String = ""): JsonElement =
        parse(raw("GET", "rest/v1/$table" + if (query.isEmpty()) "" else "?$query"))

    suspend fun insert(table: String, values: JsonObject): JsonElement =
        parse(raw("POST", "rest/v1/$table", body = values, prefer = "return=representation"))

    suspend fun upsert(table: String, values: JsonObject, onConflict: String): JsonElement =
        parse(raw("POST", "rest/v1/$table?on_conflict=$onConflict", body = values,
                  prefer = "resolution=merge-duplicates,return=representation"))

    suspend fun update(table: String, values: JsonObject, match: String): JsonElement =
        parse(raw("PATCH", "rest/v1/$table?$match", body = values, prefer = "return=representation"))

    // ------------------------------------------------------ functions, files

    suspend fun invokeFunction(name: String, body: JsonObject): JsonElement =
        parse(raw("POST", "functions/v1/$name", body = body))

    suspend fun upload(bucket: String, path: String, bytes: ByteArray, contentType: String) {
        raw("POST", "storage/v1/object/$bucket/$path",
            rawBody = bytes.toRequestBody(contentType.toMediaType()), extraHeaders = mapOf("x-upsert" to "false"))
    }

    suspend fun download(bucket: String, path: String): ByteArray =
        raw("GET", "storage/v1/object/$bucket/$path")

    suspend fun removeFile(bucket: String, path: String) {
        raw("DELETE", "storage/v1/object/$bucket/$path")
    }

    // -------------------------------------------------------------- plumbing

    inline fun <reified T> decode(element: JsonElement): T = try {
        SupabaseJson.decodeFromJsonElement(element)
    } catch (e: Exception) {
        throw SupabaseException.Decoding(e.message?.take(160) ?: "?")
    }

    fun <T> decodeWith(serializer: kotlinx.serialization.KSerializer<T>, element: JsonElement): T = try {
        SupabaseJson.decodeFromJsonElement(serializer, element)
    } catch (e: Exception) {
        throw SupabaseException.Decoding(e.message?.take(160) ?: "?")
    }

    inline fun <reified T> decode(bytes: ByteArray): T = decode(parse(bytes))

    fun parse(bytes: ByteArray): JsonElement =
        if (bytes.isEmpty()) JsonNull else try {
            SupabaseJson.parseToJsonElement(bytes.decodeToString())
        } catch (e: Exception) {
            throw SupabaseException.Decoding(e.message?.take(160) ?: "?")
        }

    private suspend fun raw(
        method: String,
        path: String,
        body: JsonObject? = null,
        rawBody: RequestBody? = null,
        prefer: String? = null,
        extraHeaders: Map<String, String> = emptyMap(),
        allowRefresh: Boolean = true,
    ): ByteArray {
        if (base.isEmpty() || anonKey.isEmpty()) throw SupabaseException.NotConfigured()
        val tokenUsed = accessToken
        val (status, bytes) = execute(method, path, body, rawBody, prefer, extraHeaders, tokenUsed)
        if (status == 401 && allowRefresh && refreshToken != null && refreshOnce(tokenUsed)) {
            val (retryStatus, retryBytes) = execute(method, path, body, rawBody, prefer, extraHeaders, accessToken)
            return check(retryStatus, retryBytes)
        }
        if (status == 401 && allowRefresh && tokenUsed != null) throw SupabaseException.Unauthenticated()
        return check(status, bytes)
    }

    private fun check(status: Int, bytes: ByteArray): ByteArray {
        if (status in 200..299) return bytes
        throw SupabaseException.Http(status, errorMessage(bytes))
    }

    private fun errorMessage(bytes: ByteArray): String = runCatching {
        val obj = SupabaseJson.parseToJsonElement(bytes.decodeToString()).jsonObject
        (obj["message"] ?: obj["error_description"] ?: obj["msg"] ?: obj["error"])?.jsonPrimitive?.content
    }.getOrNull() ?: ""

    private suspend fun execute(
        method: String, path: String, body: JsonObject?, rawBody: RequestBody?,
        prefer: String?, extraHeaders: Map<String, String>, token: String?,
    ): Pair<Int, ByteArray> = withContext(Dispatchers.IO) {
        val requestBody = rawBody ?: body?.toString()?.toRequestBody(jsonType)
            ?: if (method == "POST" || method == "PATCH") "{}".toRequestBody(jsonType) else null
        val builder = Request.Builder()
            .url("$base/$path".toHttpUrl())
            .method(method, requestBody)
            .header("apikey", anonKey)
            .header("Authorization", "Bearer ${token ?: anonKey}")
        if (rawBody == null) builder.header("Content-Type", "application/json")
        prefer?.let { builder.header("Prefer", it) }
        extraHeaders.forEach { (k, v) -> builder.header(k, v) }
        try {
            http.newCall(builder.build()).execute().use { response ->
                response.code to (response.body?.bytes() ?: ByteArray(0))
            }
        } catch (e: IOException) {
            throw SupabaseException.Offline()
        }
    }
}
