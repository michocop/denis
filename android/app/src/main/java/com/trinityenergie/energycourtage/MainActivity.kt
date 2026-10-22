package com.trinityenergie.energycourtage

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
import com.trinityenergie.energycourtage.ui.root.RootScreen
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.TrinityTheme
import kotlinx.coroutines.launch

/** One activity; what it shows is AppModel's phase (iOS AppRootView). A
 *  FragmentActivity, because BiometricPrompt needs one. */
class MainActivity : FragmentActivity() {
    private val model: AppModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        splash.setKeepOnScreenCondition { model.phase.value is AppModel.Phase.Launching }
        // the app is dark: light icons on both bars, whatever the phone's theme
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)

        if (intent.hasExtra("demo")) model.startDemo(asAdmin = intent.getBooleanExtra("admin", false))

        setContent {
            TrinityTheme {
                val phase by model.phase.collectAsStateWithLifecycle()
                val scope = rememberCoroutineScope()
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
                        is AppModel.Phase.Ready -> RootScreen(p, onSignOut = model::signOut)
                    }
                }
            }
        }
    }
}
