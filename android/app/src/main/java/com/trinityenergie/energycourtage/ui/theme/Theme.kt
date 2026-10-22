package com.trinityenergie.energycourtage.ui.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.trinityenergie.energycourtage.R

/**
 * Design tokens, the same values as the iPhone app's Theme.swift, taken from
 * trinity-energie.fr: a night-navy canvas, one electric blue, glass surfaces
 * with a hairline of light on their edge, Sora for display and Manrope for
 * text. The app is dark, like the site.
 */
object Palette {
    val night = Color(0xFF03081A)
    val navy = Color(0xFF0A1F4A)
    val brandFill = Color(0xFF1F5FFF)
    val brand = Color(0xFF4F95FF)
    val brandSoft = Color(0xFF1F5FFF).copy(alpha = 0.16f)
    val ice = Color(0xFFC3D7FF)

    val success = Color(0xFF34D399)
    val successText = Color(0xFF5EE6A8)
    val successSoft = Color(0xFF34D399).copy(alpha = 0.13f)

    val rewardSoft = Color(0xFFF5C451).copy(alpha = 0.14f)
    val rewardText = Color(0xFFF5C451)

    val destructive = Color(0xFFFF8A80)

    val textPrimary = Color(0xFFF5F7FC)
    val textSecondary = Color(0xFFDCE5F7).copy(alpha = 0.58f)

    val surface = Color(0xFF0B1430)
    val canvas = night
    val track = Color.White.copy(alpha = 0.06f)
    val grouped = Color.White.copy(alpha = 0.06f)
    val hairline = Color.White.copy(alpha = 0.10f)

    val pendingRing = Color.White.copy(alpha = 0.22f)
    val connectorIdle = Color.White.copy(alpha = 0.12f)
    val avatar = Color(0xFF1F5FFF).copy(alpha = 0.28f)

    val staleSoft = Color(0xFFFB923C).copy(alpha = 0.14f)
    val staleText = Color(0xFFFDBA74)

    val logoInner = Color(0xFF3C8BFF)
    val logoGlow = Color(0xFF9CC4FF)
}

object Radius {
    val card = 24.dp
    val field = 16.dp
    val button = 999.dp
    val modal = 28.dp
    val image = 14.dp
}

object Spacing {
    val gutter = 20.dp
    val cardPadding = 20.dp
    val xs = 4.dp
    val s = 8.dp
    val m = 12.dp
    val l = 16.dp
    val xl = 24.dp
}

// Sora and Manrope ship as one variable font each (SIL OFL), so a weight is a
// variation of the same file, as on iOS.
@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
private fun variable(res: Int, weight: FontWeight) =
    Font(res, weight, variationSettings = FontVariation.Settings(FontVariation.weight(weight.weight)))

val Sora = FontFamily(
    variable(R.font.sora, FontWeight.Normal), variable(R.font.sora, FontWeight.Medium),
    variable(R.font.sora, FontWeight.SemiBold), variable(R.font.sora, FontWeight.Bold),
)
val Manrope = FontFamily(
    variable(R.font.manrope, FontWeight.Normal), variable(R.font.manrope, FontWeight.Medium),
    variable(R.font.manrope, FontWeight.SemiBold), variable(R.font.manrope, FontWeight.Bold),
)

object Type {
    val screenTitle = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 32.sp, lineHeight = 38.sp)
    val cardTitle = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 21.sp, lineHeight = 26.sp)
    val amount = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 20.sp)
    val statValue = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 26.sp)
    val body = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Normal, fontSize = 17.sp, lineHeight = 23.sp)
    val secondary = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 21.sp)
    val label = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium, fontSize = 15.sp)
    val badge = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
    val caption = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium, fontSize = 13.sp)
    val button = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
    val wordmark = TextStyle(fontFamily = Sora, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, letterSpacing = 2.2.sp)
}

/** The site's headline treatment: blue to ice, left to right. */
val BrandGradient = Brush.horizontalGradient(listOf(Color(0xFF4F95FF), Color(0xFF7DB0FF), Palette.ice))

@Composable
fun TrinityTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Palette.brandFill,
            onPrimary = Color.White,
            secondary = Palette.brand,
            background = Palette.night,
            onBackground = Palette.textPrimary,
            surface = Palette.surface,
            onSurface = Palette.textPrimary,
            surfaceVariant = Palette.surface,
            onSurfaceVariant = Palette.textSecondary,
            error = Palette.destructive,
            outline = Palette.hairline,
        ),
        content = content,
    )
}

/** The canvas: night, with the navy glow the site has at the top of its hero
 *  and a faint blue bloom behind it. */
@Composable
fun BrandBackground(modifier: Modifier = Modifier, content: @Composable () -> Unit = {}) {
    Box(
        modifier
            .fillMaxSize()
            .background(Palette.night)
            .drawBehind {
                drawRect(Brush.radialGradient(
                    listOf(Palette.navy.copy(alpha = 0.95f), Color.Transparent),
                    center = Offset(size.width * 0.5f, -size.height * 0.05f), radius = 520.dp.toPx()))
                drawRect(Brush.radialGradient(
                    listOf(Palette.brandFill.copy(alpha = 0.16f), Color.Transparent),
                    center = Offset(size.width * 0.85f, size.height * 0.05f), radius = 300.dp.toPx()))
            }
    ) { content() }
}

/** The glass card: the site's `--glass` gradient over the canvas, a hairline
 *  of light on the edge, brighter along the top, and a deep soft shadow. */
fun Modifier.cardSurface(radius: Dp = Radius.card): Modifier {
    val shape = RoundedCornerShape(radius)
    return this
        .shadow(24.dp, shape, ambientColor = Color.Black.copy(alpha = 0.45f), spotColor = Color.Black.copy(alpha = 0.45f))
        .background(Palette.night.copy(alpha = 0.35f), shape)
        .background(Brush.linearGradient(listOf(Color.White.copy(alpha = 0.085f), Color.White.copy(alpha = 0.025f))), shape)
        .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.18f), Color.White.copy(alpha = 0.05f))), shape)
}

/** Glass for floating controls: the bell, segmented tracks. */
fun Modifier.brandGlass(radius: Dp = Radius.button): Modifier {
    val shape = RoundedCornerShape(radius)
    return this.background(Color.White.copy(alpha = 0.06f), shape).border(1.dp, Color.White.copy(alpha = 0.14f), shape)
}

/** The Trinity Énergie mark, drawn so it is sharp at every size: an open
 *  triangle and a solid blue one inside it (the site's SVG, viewBox 24×22). */
@Composable
fun TrinityLogo(size: Dp = 28.dp, lineColor: Color = Palette.textPrimary, charge: Float = 0f) {
    Canvas(Modifier.size(size, size * 22f / 24f).semantics { contentDescription = "Trinity Énergie" }) {
        val sx = this.size.width / 24f
        val sy = this.size.height / 22f
        val outer = Path().apply {
            moveTo(12 * sx, 1.25f * sy); lineTo(22.5f * sx, 20.75f * sy); lineTo(1.5f * sx, 20.75f * sy); close()
        }
        drawPath(outer, lineColor, style = Stroke(width = this.size.width * 1.8f / 24f, join = StrokeJoin.Round))
        val scale = 1f + 0.14f * charge
        val cy = (8.75f + 17f + 17f) / 3f * sy
        fun p(x: Float, y: Float) = Offset(12 * sx + (x * sx - 12 * sx) * scale, cy + (y * sy - cy) * scale)
        val inner = Path().apply {
            val a = p(12f, 8.75f); val b = p(16.5f, 17f); val c = p(7.5f, 17f)
            moveTo(a.x, a.y); lineTo(b.x, b.y); lineTo(c.x, c.y); close()
        }
        drawPath(inner, Palette.logoInner)
        if (charge > 0f) drawPath(inner, Palette.logoGlow.copy(alpha = charge))
    }
}

/** The mark and the letter-spaced name, as in the site's header. */
@Composable
fun TrinityWordmark(logoSize: Dp = 22.dp) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        TrinityLogo(logoSize)
        Text("TRINITY ÉNERGIE", style = Type.wordmark, color = Palette.textPrimary)
    }
}
