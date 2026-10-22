package com.trinityenergie.energycourtage.push

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.model.Route
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/**
 * Push notifications, end to end on the phone (iOS PushCenter and
 * PushRegistration).
 *
 *  - [init], from TrinityApp.onCreate: the notification channel, and Firebase
 *    if android/firebase.properties was filled in at build time. Without it
 *    nothing here talks to Google, and every other call is a no-op.
 *  - [register], once someone is signed in: hands the phone's FCM token to
 *    `register_device_token`. A token FCM rotates later is registered by
 *    [TrinityMessagingService.onNewToken] under the same session.
 *  - [routeFrom], on a launch or a new intent: the screen a tapped
 *    notification asked for.
 *  - [RequestNotificationPermission]: Android 13's permission, asked once.
 *
 * Signing out forgets the phone server-side (`forget_my_device_tokens`, in
 * AppModel); the next person to sign in registers it again under their name.
 */
object Push {
    private const val TAG = "Push"
    private const val PREFS = "push"
    private const val ASKED_PERMISSION = "asked_post_notifications"
    private const val TOKEN_FILE = "fcm_token"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The session [register] last ran for, so a rotated token joins it. */
    @Volatile private var session: Dependencies? = null

    /** Whether this build carries the Firebase app's values (android/firebase.properties). */
    fun isConfigured(context: Context): Boolean = PushConfig.fromBuild.isComplete

    /** From TrinityApp.onCreate. Safe to call more than once. */
    fun init(context: Context) {
        val app = context.applicationContext
        runCatching { PushNotifications.createChannels(app) }
        if (!isConfigured(app)) return
        try {
            if (FirebaseApp.getApps(app).isEmpty()) {
                FirebaseApp.initializeApp(app, PushConfig.fromBuild.options())
            }
            // the manifest keeps this off until Firebase has been set up here
            FirebaseMessaging.getInstance().isAutoInitEnabled = true
        } catch (e: Exception) {
            Log.w(TAG, "Firebase could not start; push stays off", e)
        }
    }

    private fun firebaseReady(context: Context): Boolean =
        isConfigured(context) && runCatching { FirebaseApp.getApps(context.applicationContext).isNotEmpty() }.getOrDefault(false)

    /**
     * Registers this phone for the signed-in person. Call it once a session is
     * ready (and again on each new sign-in). Does nothing in demo mode or when
     * push is not configured, and never throws: no push is not a reason to
     * fail anything else.
     */
    suspend fun register(context: Context, deps: Dependencies) {
        if (deps.isDemo || deps.client == null || !firebaseReady(context)) return
        session = deps
        val token = try {
            withTimeoutOrNull(30_000) { FirebaseMessaging.getInstance().token.await() }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // no Play services, or offline: onNewToken registers it when it comes
            Log.w(TAG, "no FCM token yet", e)
            null
        } ?: storedToken(context) ?: return
        store(context, token)
        send(deps, token)
    }

    /** A token FCM handed over (TrinityMessagingService.onNewToken). */
    internal fun tokenReceived(context: Context, token: String) {
        store(context, token)
        val deps = session ?: return
        scope.launch { send(deps, token) }
    }

    private suspend fun send(deps: Dependencies, token: String) {
        val client = deps.client ?: return
        // signed out since: the token waits for the next person's register()
        if (client.userId == null || session !== deps) return
        try {
            client.rpcVoid("register_device_token", buildJsonObject {
                put("p_token", token)
                put("p_platform", "android")
            })
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "register_device_token failed: ${e.message}")
        }
    }

    // The token is kept out of backups (noBackupFilesDir): restored on another
    // phone it would name this one.
    private fun tokenFile(context: Context) = File(context.applicationContext.noBackupFilesDir, TOKEN_FILE)

    private fun store(context: Context, token: String) {
        runCatching { tokenFile(context).writeText(token) }
    }

    private fun storedToken(context: Context): String? =
        runCatching { tokenFile(context).takeIf { it.exists() }?.readText()?.trim() }.getOrNull()?.takeIf { it.isNotEmpty() }

    /**
     * The screen a tapped notification asked for, or null. Reads the extras
     * this app's own notifications carry and the `data` keys FCM copies into
     * the launch intent when the system drew the notification.
     */
    fun routeFrom(intent: Intent?): Route? {
        val extras = intent?.extras ?: return null
        val data = PushRoute.routeKeys.associateWith { key ->
            // FCM's extras are strings; anything else under these keys is not ours
            runCatching { extras.getString(key) }.getOrNull()
        }
        return PushRoute.parse(data)
    }

    /**
     * Asks for POST_NOTIFICATIONS on Android 13 and later, once per install
     * (remembered in SharedPreferences, so a refusal is respected; Settings can
     * still turn it on). Asks nothing when push is not configured, so the one
     * question is kept for when the answer matters.
     */
    @Composable
    fun RequestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        val context = LocalContext.current
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
        LaunchedEffect(Unit) {
            if (!isConfigured(context)) return@LaunchedEffect
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            ) return@LaunchedEffect
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (prefs.getBoolean(ASKED_PERMISSION, false)) return@LaunchedEffect
            prefs.edit().putBoolean(ASKED_PERMISSION, true).apply()
            launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
