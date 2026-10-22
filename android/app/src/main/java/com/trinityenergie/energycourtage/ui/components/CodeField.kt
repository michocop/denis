package com.trinityenergie.energycourtage.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.keyframes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Sora

enum class CodePhase { Entering, Checking, Wrong, Accepted }

/**
 * Six boxes over one hidden field: the keyboard's code suggestion fills all
 * six at once, a paste works, and the sixth digit submits (iOS SmsCodeField).
 * A wrong code shakes the row; an accepted one turns it green.
 */
@Composable
fun CodeField(
    code: String,
    onCodeChange: (String) -> Unit,
    phase: CodePhase,
    shakes: Int,
    accessibilityLabel: String,
    enabled: Boolean = true,
    onComplete: (String) -> Unit,
) {
    val focus = remember { FocusRequester() }
    val haptics = LocalHapticFeedback.current
    val shake = remember { Animatable(0f) }

    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    LaunchedEffect(shakes) {
        if (shakes > 0) {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            shake.animateTo(0f, keyframes {
                durationMillis = 360
                -12f at 50; 12f at 110; -9f at 170; 9f at 230; -4f at 290; 0f at 360
            })
        }
    }

    BasicTextField(
        value = code,
        onValueChange = { raw ->
            val digits = raw.filter(Char::isDigit).take(6)
            onCodeChange(digits)
            if (digits.length == 6) onComplete(digits)
        },
        enabled = enabled,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
        textStyle = TextStyle(color = Color.Transparent),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(Color.Transparent),
        modifier = Modifier
            .fillMaxWidth()
            .focusRequester(focus)
            .semantics { contentDescription = accessibilityLabel },
        decorationBox = {
            Row(
                Modifier.fillMaxWidth().offset { IntOffset(shake.value.dp.roundToPx(), 0) },
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                repeat(6) { i ->
                    val char = code.getOrNull(i)?.toString() ?: ""
                    val active = i == code.length && phase == CodePhase.Entering
                    val border by animateColorAsState(
                        when (phase) {
                            CodePhase.Wrong -> Palette.destructive
                            CodePhase.Accepted -> Palette.success
                            else -> if (active) Palette.brand else Palette.hairline
                        }, label = "box",
                    )
                    val shape = RoundedCornerShape(14.dp)
                    Box(
                        Modifier
                            .weight(1f)
                            .aspectRatio(0.82f)
                            .background(Color.White.copy(alpha = 0.04f), shape)
                            .border(if (active) 1.5.dp else 1.dp, border, shape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(char, style = TextStyle(fontFamily = Sora, fontSize = 26.sp,
                            color = if (phase == CodePhase.Accepted) Palette.successText else Palette.textPrimary))
                    }
                }
            }
        },
    )
}
