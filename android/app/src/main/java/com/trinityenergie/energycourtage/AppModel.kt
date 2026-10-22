package com.trinityenergie.energycourtage

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.trinityenergie.energycourtage.core.BiometricGate
import com.trinityenergie.energycourtage.core.SessionStore
import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.core.SupabaseException
import com.trinityenergie.energycourtage.data.DemoProfileRepository
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.SupabaseProfileRepository
import com.trinityenergie.energycourtage.model.AccountState
import com.trinityenergie.energycourtage.model.UserRole
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Owns the session and decides what the app shows.
 *
 * The decision comes from my_account_state() rather than from anything the
 * client works out for itself: whether an account is ready, awaiting approval
 * or suspended is the server's answer (App/AppRoot.swift on iOS).
 */
class AppModel(application: Application) : AndroidViewModel(application) {

    sealed interface Phase {
        data object Launching : Phase
        data class SignedOut(val notice: String? = null) : Phase
        /** Signed in for the first time: the invitation opened the account,
         *  and it has no name yet. */
        data class CompletingInvite(val email: String) : Phase
        data class PendingApproval(val email: String) : Phase
        data object Suspended : Phase
        data object Locked : Phase
        data class Ready(val deps: Dependencies, val role: UserRole, val fullName: String, val isDemo: Boolean) : Phase
    }

    private val _phase = MutableStateFlow<Phase>(Phase.Launching)
    val phase: StateFlow<Phase> = _phase

    private val sessionStore = SessionStore(application)
    private var client: SupabaseClient? = null
    private var email = ""

    val canOfferDemo = true

    init { viewModelScope.launch { start() } }

    private suspend fun start() {
        val url = BuildConfig.SUPABASE_URL
        val key = BuildConfig.SUPABASE_ANON_KEY
        // No backend configured means nothing to sign in to: the sample data
        // rather than a sign-in form that cannot work.
        if (url.isBlank() || key.isBlank()) { startDemo(asAdmin = false); return }

        val c = SupabaseClient(url, key)
        c.onRefreshTokenRotated = { sessionStore.save(it) }
        client = c

        val stored = sessionStore.refreshToken()
        if (stored == null) { _phase.value = Phase.SignedOut(); return }
        try {
            val session = c.restore(stored)
            email = session.user.email ?: ""
            _phase.value = if (BiometricGate.isAvailable(getApplication())) Phase.Locked else resolvePhase()
        } catch (e: SupabaseException.Offline) {
            _phase.value = Phase.SignedOut(e.message)
        } catch (e: Exception) {
            sessionStore.clear()
            _phase.value = Phase.SignedOut()
        }
    }

    fun startDemo(asAdmin: Boolean) {
        val role = if (asAdmin) UserRole.Admin else UserRole.Apporteur
        val name = if (asAdmin) "Pierre-Louis Tettamanti" else "Johann Lefeuvre"
        _phase.value = Phase.Ready(
            Dependencies(client = null, isDemo = true, role = role, fullName = name, profiles = DemoProfileRepository(role)),
            role, name, isDemo = true,
        )
    }

    /** Emails the six-digit code. Throws EmailCodeException for the screen. */
    suspend fun sendEmailCode(address: String) {
        val c = client ?: throw SupabaseException.NotConfigured()
        c.sendEmailCode(address.trim().lowercase())
    }

    suspend fun verifyEmailCode(code: String, address: String) {
        val c = client ?: throw SupabaseException.NotConfigured()
        val session = c.verifyEmailCode(code, address.trim().lowercase())
        email = session.user.email ?: address
        _phase.value = resolvePhase()
    }

    /** The first sign-in of an invited address: the invitation sent to it
     *  gives the role, matched by email, so the code is empty. */
    suspend fun completeInvite(firstName: String, lastName: String) {
        val c = client ?: throw SupabaseException.NotConfigured()
        c.rpc("redeem_invite", buildJsonObject {
            put("p_code", ""); put("p_first_name", firstName); put("p_last_name", lastName)
        })
        _phase.value = resolvePhase()
    }

    fun refresh() { viewModelScope.launch { _phase.value = resolvePhase() } }

    fun onUnlocked() { viewModelScope.launch { _phase.value = resolvePhase() } }

    fun signOut() {
        val c = client
        viewModelScope.launch {
            runCatching { c?.rpcVoid("forget_my_device_tokens") }
            c?.clearSession()
            sessionStore.clear()
            _phase.value = Phase.SignedOut()
        }
    }

    private suspend fun resolvePhase(): Phase {
        val c = client ?: return Phase.SignedOut()
        return try {
            val account: AccountState = c.decode(c.rpc("my_account_state"))
            when (account.state) {
                "ready" -> {
                    val role = account.role ?: UserRole.Apporteur
                    val name = account.fullName ?: ""
                    Phase.Ready(
                        Dependencies(client = c, isDemo = false, role = role, fullName = name, profiles = SupabaseProfileRepository(c)),
                        role, name, isDemo = false,
                    )
                }
                "pending_approval" -> Phase.PendingApproval(email)
                "needs_invite" -> Phase.CompletingInvite(email)
                "suspended" -> Phase.Suspended
                else -> Phase.SignedOut()
            }
        } catch (e: Exception) {
            Phase.SignedOut(e.message)
        }
    }
}
