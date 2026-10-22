package com.trinityenergie.energycourtage.core

import android.content.Context
import android.content.SharedPreferences
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Only the refresh token is kept, encrypted with a key held by the Android
 * Keystore, and never backed up (backup_rules.xml): the Keychain's
 * WhenUnlockedThisDeviceOnly on iOS. The access token lives in memory.
 */
class SessionStore(context: Context) {
    private val prefs: SharedPreferences? = runCatching {
        val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context, "session", key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }.getOrNull()

    fun refreshToken(): String? = prefs?.getString(KEY, null)

    fun save(refreshToken: String?) {
        prefs?.edit()?.apply { if (refreshToken == null) remove(KEY) else putString(KEY, refreshToken) }?.apply()
    }

    fun clear() = save(null)

    private companion object { const val KEY = "supabase.refresh_token" }
}

/** "Espace verrouillé": a restored session waits for the fingerprint, the
 *  face or the device code. With none set up on the phone, it lets through,
 *  as LAContext does on iOS. */
object BiometricGate {
    private const val AUTHENTICATORS = BIOMETRIC_STRONG or DEVICE_CREDENTIAL

    fun isAvailable(context: Context): Boolean =
        BiometricManager.from(context).canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS

    suspend fun unlock(activity: FragmentActivity): Boolean {
        if (!isAvailable(activity)) return true
        return suspendCancellableCoroutine { continuation ->
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (continuation.isActive) continuation.resume(true)
                    }
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (continuation.isActive) continuation.resume(false)
                    }
                })
            prompt.authenticate(
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle("Déverrouiller Trinity Énergie")
                    .setSubtitle("Votre espace apporteur")
                    .setAllowedAuthenticators(AUTHENTICATORS)
                    .build()
            )
        }
    }
}
