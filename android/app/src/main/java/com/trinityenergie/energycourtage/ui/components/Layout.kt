package com.trinityenergie.energycourtage.ui.components

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Radius
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.brandGlass
import com.trinityenergie.energycourtage.ui.theme.cardSurface

/** The `Actives | Archivées` picker: the brand-blue pill sliding over a glass
 *  track, as the site draws its selected state (iOS SegmentedPicker). */
@Composable
fun <T> SegmentedPicker(selection: T, options: List<Pair<T, String>>, onSelect: (T) -> Unit, modifier: Modifier = Modifier) {
    val haptics = LocalHapticFeedback.current
    val index = options.indexOfFirst { it.first == selection }.coerceAtLeast(0)
    val animated by androidx.compose.animation.core.animateFloatAsState(index.toFloat(), label = "pill")
    Row(
        modifier.fillMaxWidth().brandGlass().padding(4.dp).drawBehind {
            val segment = size.width / options.size
            val r = androidx.compose.ui.geometry.CornerRadius(size.height / 2)
            // a soft glow, then the pill
            drawRoundRect(Palette.brandFill.copy(alpha = 0.25f), topLeft = androidx.compose.ui.geometry.Offset(segment * animated - 2f, 2f),
                size = androidx.compose.ui.geometry.Size(segment + 4f, size.height + 4f), cornerRadius = r)
            drawRoundRect(Palette.brandFill, topLeft = androidx.compose.ui.geometry.Offset(segment * animated, 0f),
                size = androidx.compose.ui.geometry.Size(segment, size.height), cornerRadius = r)
        },
    ) {
        options.forEach { (value, title) ->
            val selected = value == selection
            Text(
                title,
                style = Type.label.copy(fontWeight = Type.button.fontWeight),
                color = if (selected) Color.White else Palette.textSecondary,
                textAlign = TextAlign.Center,
                maxLines = 1,
                modifier = Modifier.weight(1f).clickable(indication = null, interactionSource = null) {
                    if (!selected) { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); onSelect(value) }
                }.padding(vertical = 11.dp),
            )
        }
    }
}

@Composable
fun SearchField(placeholder: String, text: String, onTextChange: (String) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().cardSurface(Radius.field).padding(horizontal = Spacing.l, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Icon(Icons.Filled.Search, null, tint = Palette.textSecondary, modifier = Modifier.size(22.dp))
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text(placeholder, style = Type.body, color = Palette.textSecondary)
            BasicTextField(text, onTextChange, singleLine = true, textStyle = Type.body.copy(color = Palette.textPrimary),
                cursorBrush = SolidColor(Palette.brand), modifier = Modifier.fillMaxWidth())
        }
        if (text.isNotEmpty()) {
            IconButton(onClick = { onTextChange("") }, modifier = Modifier.size(24.dp)) {
                Icon(Icons.Filled.Close, "Effacer la recherche", tint = Palette.textSecondary)
            }
        }
    }
}

/**
 * A screen presented over the tabs -- iOS's sheets and pushed views. Full
 * screen, the brand background, a title bar with a close (or back) control,
 * content that scrolls unless [scrolls] is false. Dismissed by the system back
 * gesture too.
 */
@Composable
fun FullScreenSheet(
    title: String,
    onDismiss: (() -> Unit)?,
    back: Boolean = false,
    scrolls: Boolean = true,
    actions: @Composable () -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(
        onDismissRequest = { onDismiss?.invoke() },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false,
            dismissOnBackPress = onDismiss != null, dismissOnClickOutside = false),
    ) {
        BrandBackground {
            Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.s, vertical = Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                    if (onDismiss != null) {
                        IconButton(onClick = onDismiss) {
                            Icon(if (back) Icons.AutoMirrored.Filled.ArrowBack else Icons.Filled.Close,
                                if (back) "Retour" else "Fermer", tint = Palette.textPrimary)
                        }
                    } else Spacer(Modifier.size(48.dp))
                    Text(title, style = Type.label.copy(fontWeight = Type.button.fontWeight, fontFamily = Type.cardTitle.fontFamily),
                        color = Palette.textPrimary, maxLines = 1, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                    Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { actions() }
                }
                val inner = Modifier.fillMaxWidth().weight(1f).padding(horizontal = Spacing.gutter)
                Column(
                    if (scrolls) inner.verticalScroll(rememberScrollState()).padding(bottom = Spacing.xl) else inner,
                    verticalArrangement = Arrangement.spacedBy(Spacing.l),
                    content = content,
                )
            }
        }
    }
}

/** A titled screen in a tab: the large Sora title, then the content. */
@Composable
fun ScreenTitle(title: String, modifier: Modifier = Modifier, trailing: @Composable () -> Unit = {}) {
    Row(modifier.fillMaxWidth().padding(top = Spacing.s), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Type.screenTitle, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        trailing()
    }
}

/** Nothing to show yet, said kindly, with what to do about it. */
@Composable
fun EmptyState(icon: ImageVector, title: String, body: String? = null, modifier: Modifier = Modifier, action: @Composable () -> Unit = {}) {
    Column(modifier.fillMaxWidth().padding(vertical = Spacing.xl * 2), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Icon(icon, null, tint = Palette.textSecondary, modifier = Modifier.size(40.dp))
        Text(title, style = Type.cardTitle, color = Palette.textPrimary, textAlign = TextAlign.Center)
        if (body != null) Text(body, style = Type.secondary, color = Palette.textSecondary, textAlign = TextAlign.Center)
        action()
    }
}

@Composable
fun LoadingBlock(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(Spacing.xl), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Palette.brand, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
    }
}

/** A confirmation, iOS's confirmationDialog/alert: a title, a line, one
 *  confirm action (destructive when it removes or closes something). */
@Composable
fun ConfirmDialog(
    title: String,
    message: String?,
    confirm: String,
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    extra: @Composable (() -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = Type.cardTitle) },
        text = if (message != null || extra != null) ({
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                message?.let { Text(it, style = Type.secondary) }
                extra?.invoke()
            }
        }) else null,
        confirmButton = { TextButton({ onConfirm() }) { Text(confirm, style = Type.label, color = if (destructive) Palette.destructive else Palette.brand) } },
        dismissButton = { TextButton(onDismiss) { Text("Annuler", style = Type.label, color = Palette.textSecondary) } },
        containerColor = Palette.surface,
        titleContentColor = Palette.textPrimary,
        textContentColor = Palette.textSecondary,
    )
}

/** A glass card holding a section of a screen. */
@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding), verticalArrangement = Arrangement.spacedBy(Spacing.m), content = content)
}

/** A small muted heading over a group. */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = Type.caption.copy(letterSpacing = Type.wordmark.letterSpacing), color = Palette.textSecondary, modifier = modifier.padding(start = 4.dp))
}

