package com.trinityenergie.energycourtage.pdf

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import androidx.core.content.res.ResourcesCompat
import com.trinityenergie.energycourtage.R

/** Text helpers with no Android in them, so they are tested on the JVM. */
object PdfText {
    /** Lines that fit [maxWidth], keeping explicit newlines; a word longer than
     *  the line stays whole on its own line, as on iOS. */
    fun wrap(text: String, maxWidth: Float, measure: (String) -> Float): List<String> {
        val lines = mutableListOf<String>()
        for (paragraph in text.split("\n")) {
            var line = ""
            for (word in paragraph.split(Regex("\\s+")).filter { it.isNotEmpty() }) {
                val candidate = if (line.isEmpty()) word else "$line $word"
                if (measure(candidate) <= maxWidth) {
                    line = candidate
                } else {
                    if (line.isNotEmpty()) lines += line
                    line = word
                }
            }
            lines += line
        }
        return lines
    }

    /** "300.00" from the server, "300,00 €" on the page, thousands spaced: the
     *  database sends amounts in a fixed machine format so nothing is lost to a
     *  locale, and the French way of writing them is applied only here. */
    fun money(amount: String, currency: String): String {
        val symbol = if (currency == "EUR") "€" else currency
        val parts = amount.split(".", limit = 2)
        var whole = parts.first()
        val sign = if (whole.startsWith("-")) "-" else ""
        whole = whole.replace("-", "")
        val grouped = whole.reversed().chunked(3).joinToString(" ").reversed()
        val cents = if (parts.size > 1) parts[1] else "00"
        return "$sign$grouped,$cents $symbol"
    }

    /** The digest in groups of eight, readable aloud if it ever has to be. */
    fun grouped(digest: String?): String = digest?.chunked(8)?.joinToString(" ") ?: "document non scellé"
}

/** A face at a weight: the app's bundled fonts are variable, so the weight is
 *  set on the axis rather than by file (as InvoicePDF.swift does). */
internal class Face(val typeface: Typeface, val variation: String?)

internal class PdfFonts(val body: Face, val bold: Face, val display: Face) {
    companion object {
        /** Manrope and Sora when a context can load them; the system sans
         *  otherwise, which the PDF embeds just as well. */
        fun load(context: Context?): PdfFonts {
            fun font(id: Int) = context?.let { runCatching { ResourcesCompat.getFont(it, id) }.getOrNull() }
            val manrope = font(R.font.manrope)
            val sora = font(R.font.sora)
            val sans = Typeface.SANS_SERIF
            return PdfFonts(
                body = manrope?.let { Face(it, "'wght' 400") } ?: Face(Typeface.create(sans, Typeface.NORMAL), null),
                bold = manrope?.let { Face(it, "'wght' 700") } ?: Face(Typeface.create(sans, Typeface.BOLD), null),
                display = sora?.let { Face(it, "'wght' 600") } ?: Face(Typeface.create(sans, Typeface.BOLD), null),
            )
        }
    }
}

/** One style of text: a face, a size in points, a colour, a tracking in points. */
internal class Ink(face: Face, val size: Float, color: Int, kern: Float = 0f, italic: Boolean = false) {
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        // A PDF point is one canvas unit, so body text is 7-9 units tall. At
        // that size Android hints each advance to a whole unit, and a space
        // rounds down to nothing: "Session authentifiée" came out
        // "Sessionauthentifiée". Linear, subpixel text keeps exact advances.
        isLinearText = true
        isSubpixelText = true
        typeface = face.typeface
        textSize = size
        this.color = color
        face.variation?.let { fontVariationSettings = it }
        if (kern != 0f) letterSpacing = kern / size
        if (italic) textSkewX = -0.2f
        // no ligatures: an "ff" drawn as one glyph reads back as nothing, and
        // "affaires" would not be found by a search of the filed document
        fontFeatureSettings = "'liga' 0, 'clig' 0"
    }
    private val metrics = paint.fontMetrics
    /** The height of a line box, as UIFont.lineHeight. */
    val lineHeight = metrics.descent - metrics.ascent

    fun width(s: String) = kotlin.math.ceil(paint.measureText(s))

    /** One line with its top at [y] (UIKit's draw(at:)). */
    fun draw(canvas: Canvas, s: String, x: Float, y: Float) = canvas.drawText(s, x, y - metrics.ascent, paint)

    /** One line ending at [right]. */
    fun drawRight(canvas: Canvas, s: String, right: Float, y: Float) = draw(canvas, s, right - width(s), y)

    fun wrap(text: String, maxWidth: Float) = PdfText.wrap(text, maxWidth) { width(it) }
}

internal fun hex(rgb: Int): Int = 0xFF000000.toInt() or rgb

internal fun Canvas.rule(x: Float, y: Float, length: Float, color: Int, width: Float = 0.5f) {
    drawLine(x, y, x + length, y, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color; strokeWidth = width; style = Paint.Style.STROKE
    })
}

/** The mark: an open triangle and a solid one inside (the site's SVG, 24×22). */
internal fun Canvas.trinityMark(x: Float, y: Float, size: Float, line: Int, fill: Int) {
    val s = size / 24f
    fun px(v: Float) = x + v * s
    fun py(v: Float) = y + v * s
    val outer = Path().apply { moveTo(px(12f), py(1.25f)); lineTo(px(22.5f), py(20.75f)); lineTo(px(1.5f), py(20.75f)); close() }
    drawPath(outer, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = line; style = Paint.Style.STROKE; strokeWidth = 1.8f * s; strokeJoin = Paint.Join.ROUND
    })
    val inner = Path().apply { moveTo(px(12f), py(8.75f)); lineTo(px(16.5f), py(17f)); lineTo(px(7.5f), py(17f)); close() }
    drawPath(inner, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = fill; style = Paint.Style.FILL })
}
