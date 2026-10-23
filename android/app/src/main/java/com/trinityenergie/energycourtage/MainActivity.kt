package com.trinityenergie.energycourtage

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.trinityenergie.energycourtage.core.BiometricGate
import com.trinityenergie.energycourtage.ui.auth.CompleteInviteScreen
import com.trinityenergie.energycourtage.ui.auth.LockedScreen
import com.trinityenergie.energycourtage.ui.auth.PendingApprovalScreen
import com.trinityenergie.energycourtage.ui.auth.SignInScreen
import com.trinityenergie.energycourtage.ui.auth.SuspendedScreen
import com.trinityenergie.energycourtage.ui.root.LaunchIntro
import com.trinityenergie.energycourtage.ui.root.RootScreen
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.TrinityTheme
import com.trinityenergie.energycourtage.model.Route
import com.trinityenergie.energycourtage.push.Push
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** One activity; what it shows is AppModel's phase (iOS AppRootView). A
 *  FragmentActivity, because BiometricPrompt needs one. */
class MainActivity : FragmentActivity() {
    private val model: AppModel by viewModels()
    /** A notification tapped -- cold start or while open -- waiting for the
     *  tabs to open what it is about. */
    private val pendingRoute = MutableStateFlow<Route?>(null)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Push.routeFrom(intent)?.let { pendingRoute.value = it }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        // the app is dark: light icons on both bars, whatever the phone's theme
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)

        if (savedInstanceState == null) Push.routeFrom(intent)?.let { pendingRoute.value = it }
        if (intent.hasExtra("demo")) model.startDemo(asAdmin = intent.getBooleanExtra("admin", false))

        setContent {
            TrinityTheme {
                val phase by model.phase.collectAsStateWithLifecycle()
                val scope = rememberCoroutineScope()
                var introDone by rememberSaveable { mutableStateOf(false) }
                if (!introDone) {
                    LaunchIntro(sessionKnown = phase !is AppModel.Phase.Launching) { introDone = true }
                    return@TrinityTheme
                }
                AnimatedContent(
                    targetState = phase,
                    contentKey = { it::class },
                    transitionSpec = { fadeIn() togetherWith fadeOut() },
                    label = "phase",
                ) { p ->
                    when (p) {
                        AppModel.Phase.Launching -> BrandBackground()
                        is AppModel.Phase.SignedOut -> SignInScreen(
                            notice = p.notice,
                            sendCode = model::sendEmailCode,
                            verifyCode = model::verifyEmailCode,
                            onDemo = if (model.canOfferDemo) model::startDemo else null,
                        )
                        is AppModel.Phase.CompletingInvite -> CompleteInviteScreen(p.email, model::signOut, model::completeInvite)
                        is AppModel.Phase.PendingApproval -> PendingApprovalScreen(p.email, model::refresh, model::signOut)
                        AppModel.Phase.Suspended -> SuspendedScreen(model::signOut)
                        AppModel.Phase.Locked -> LockedScreen {
                            scope.launch { if (BiometricGate.unlock(this@MainActivity)) model.onUnlocked() }
                        }
                        is AppModel.Phase.Ready -> {
                            val route by pendingRoute.collectAsStateWithLifecycle()
                            RootScreen(p, route, onRouteHandled = { pendingRoute.value = null }, onSignOut = model::signOut)
                        }
                    }
                }
            }
        }
    }
}
