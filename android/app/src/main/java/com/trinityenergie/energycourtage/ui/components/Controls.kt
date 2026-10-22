package com.trinityenergie.energycourtage.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.brandGlass

/** Every action button stops at a comfortable reach, centred: edge to edge on
 *  a large phone, a button reads as a banner (iOS ActionButtonMetrics). */
private val ButtonMaxWidth = 340.dp

/** The press feedback of iOS's PressableStyle: scale 0.97, opacity 0.85. */
@Composable
private fun Modifier.pressable(interaction: MutableInteractionSource, enabled: Boolean): Modifier {
    val pressed by interaction.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed && enabled) 0.97f else 1f, label = "press")
    return this.scale(s).alpha(if (!enabled) 0.45f else if (pressed) 0.85f else 1f)
}

/** The site's primary: a blue pill, a line of light along its top edge, a
 *  soft glow underneath. */
@Composable
fun PrimaryActionButton(
    title: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    working: Boolean = false,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val haptics = LocalHapticFeedback.current
    val pill = RoundedCornerShape(Radius.button)
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .widthIn(max = ButtonMaxWidth)
                .fillMaxWidth()
                .pressable(interaction, enabled)
                .shadow(10.dp, pill, ambientColor = Palette.brandFill.copy(alpha = 0.35f), spotColor = Palette.brandFill.copy(alpha = 0.35f))
                .background(Palette.brandFill, pill)
                .border(1.dp, Brush.verticalGradient(0f to Color.White.copy(alpha = 0.28f), 0.5f to Color.Transparent), pill)
                .clickable(interaction, indication = null, enabled = enabled && !working, role = Role.Button) {
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    onClick()
                }
                .padding(vertical = 13.dp, horizontal = Spacing.l),
            contentAlignment = Alignment.Center,
        ) {
            if (working) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
            else Text(title, style = Type.button, color = Color.White, maxLines = 1, textAlign = TextAlign.Center)
        }
    }
}

/** The site's ghost button. */
@Composable
fun SecondaryActionButton(
    title: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Row(
            Modifier
                .widthIn(max = ButtonMaxWidth)
                .fillMaxWidth()
                .pressable(interaction, enabled)
                .brandGlass()
                .clickable(interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
                .padding(vertical = 11.dp, horizontal = Spacing.l),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (icon != null) {
                Icon(icon, null, tint = Palette.textPrimary, modifier = Modifier.size(18.dp).padding(end = 0.dp))
                Box(Modifier.size(Spacing.s))
            }
            Text(title, style = Type.label.copy(fontWeight = Type.button.fontWeight), color = Palette.textPrimary, maxLines = 1)
        }
    }
}

/** A quiet action in the brand's tint, on a track. */
@Composable
fun TertiaryActionButton(title: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pill = RoundedCornerShape(Radius.button)
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .widthIn(max = ButtonMaxWidth)
                .fillMaxWidth()
                .pressable(interaction, enabled)
                .background(Palette.track, pill)
                .border(1.dp, Palette.hairline, pill)
                .clickable(interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
                .padding(vertical = 11.dp, horizontal = Spacing.l),
            contentAlignment = Alignment.Center,
        ) {
            Text(title, style = Type.label.copy(fontWeight = Type.button.fontWeight), color = Palette.brand, maxLines = 1)
        }
    }
}

/** A plain text link, for "Se déconnecter" and the like. */
@Composable
fun TextLink(title: String, color: Color = Palette.brand, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Text(
        title,
        style = Type.label,
        color = color,
        modifier = modifier.clickable(role = Role.Button, onClick = onClick).padding(Spacing.s),
    )
}

/** The site's form: a small muted label over a dark field. */
@Composable
fun LabelledField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    singleLine: Boolean = true,
    enabled: Boolean = true,
    visualTransformation: VisualTransformation = VisualTransformation.None,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(label, style = Type.caption, color = Palette.textSecondary, modifier = Modifier.padding(start = 4.dp))
        FieldBox {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = singleLine,
                enabled = enabled,
                textStyle = Type.body.copy(color = Palette.textPrimary),
                cursorBrush = SolidColor(Palette.brand),
                keyboardOptions = keyboardOptions,
                keyboardActions = keyboardActions,
                visualTransformation = visualTransformation,
                modifier = Modifier.fillMaxWidth(),
                decorationBox = { inner ->
                    if (value.isEmpty() && placeholder.isNotEmpty()) {
                        Text(placeholder, style = Type.body, color = Palette.textSecondary.copy(alpha = 0.6f))
                    }
                    inner()
                },
            )
        }
    }
}

@Composable
fun FieldBox(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(Radius.field)
    Box(
        modifier
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.04f), shape)
            .border(1.dp, Palette.hairline, shape)
            .padding(horizontal = Spacing.l, vertical = 15.dp)
    ) { content() }
}

/** A short status line on a soft green ground, as the stage banners. */
@Composable
fun StatusBanner(text: String, modifier: Modifier = Modifier, tint: Color = Palette.successText, ground: Color = Palette.successSoft) {
    Text(
        text,
        style = Type.secondary,
        color = tint,
        textAlign = TextAlign.Center,
        modifier = modifier
            .fillMaxWidth()
            .background(ground, RoundedCornerShape(14.dp))
            .padding(horizontal = Spacing.m, vertical = 10.dp),
    )
}

/** Initials in a soft blue disc, for people. */
@Composable
fun Avatar(name: String, size: androidx.compose.ui.unit.Dp = 40.dp) {
    val initials = name.split(" ").filter { it.isNotBlank() }.take(2).joinToString("") { it.first().uppercase() }
    Box(Modifier.size(size).background(Palette.avatar, CircleShape), contentAlignment = Alignment.Center) {
        Text(initials, style = Type.badge, color = Palette.textPrimary)
    }
}
