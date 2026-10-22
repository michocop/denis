package com.trinityenergie.energycourtage.ui.root

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.TrinityLogo
import com.trinityenergie.energycourtage.ui.theme.Type
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The opening, "Impulsion" (iOS LaunchIntroView): the inner triangle charges,
 * two waves leave it with a soft knock, and the name is drawn in from the
 * left -- about a second, played while the session is restored. If that takes
 * longer, the mark breathes. It hands over once it has played AND the app
 * knows what to show.
 */
@Composable
fun LaunchIntro(sessionKnown: Boolean, onFinished: () -> Unit) {
    val haptics = LocalHapticFeedback.current
    val charge = remember { Animatable(0f) }
    val wave1 = remember { Animatable(0f) }
    val wave2 = remember { Animatable(0f) }
    val reveal = remember { Animatable(0f) }
    var played by remember { mutableStateOf(false) }
    val known by rememberUpdatedState(sessionKnown)
    var left by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        delay(100)
        charge.animateTo(1f, tween(120, easing = LinearEasing))
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        coroutineScope {
            launch { charge.animateTo(0f, spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow)) }
            launch { wave1.animateTo(1f, tween(900, easing = FastOutSlowInEasing)) }
            launch { delay(130); wave2.animateTo(1f, tween(900, easing = FastOutSlowInEasing)) }
            launch { delay(130); reveal.animateTo(1f, tween(400, easing = FastOutSlowInEasing)) }
        }
        played = true
    }
    // played, still waiting on the network: the mark breathes
    LaunchedEffect(played, sessionKnown) {
        if (played && !known) charge.animateTo(0.5f, infiniteRepeatable(tween(900), RepeatMode.Reverse))
    }
    LaunchedEffect(played, sessionKnown) {
        if (played && sessionKnown && !left) { left = true; onFinished() }
    }

    BrandBackground {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(340.dp)) {
                fun ring(progress: Float, peak: Float, width: Float) {
                    if (progress <= 0f) return
                    val radius = (20.dp.toPx() + progress * (170.dp.toPx() - 20.dp.toPx()))
                    // lit only once it has cleared the mark
                    val alpha = when {
                        progress < 0.08f -> 0f
                        progress < 0.2f -> peak * (progress - 0.08f) / 0.12f
                        else -> peak * (1f - (progress - 0.2f) / 0.8f)
                    }.coerceIn(0f, 1f)
                    drawCircle(Palette.brand.copy(alpha = alpha), radius, center.copy(y = center.y + 6.dp.toPx()), style = Stroke(width.dp.toPx()))
                }
                ring(wave1.value, 0.9f, 1.6f)
                ring(wave2.value, 0.6f, 1.1f)
            }
            // the mark stays exactly where the splash screen drew it; the name
            // is placed under it without moving it
            TrinityLogo(size = 86.dp, charge = charge.value)
            Text(
                "TRINITY ÉNERGIE",
                style = Type.wordmark.copy(letterSpacing = Type.wordmark.letterSpacing * 1.45f),
                color = Palette.textPrimary,
                modifier = Modifier.offset(y = 86.dp * 22f / 24f / 2f + 34.dp).alpha(reveal.value).drawWithContent {
                    clipRect(right = size.width * reveal.value) { this@drawWithContent.drawContent() }
                },
            )
        }
    }
}
