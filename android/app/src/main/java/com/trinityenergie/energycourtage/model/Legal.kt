package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.time.Instant

/**
 * A document someone is asked to agree to, with the exact text they are shown.
 *
 * The body travels with it deliberately: what gets recorded on acceptance is
 * the digest of these bytes, so the app must display the thing it hashes.
 */
@Serializable
data class LegalDocument(
    val key: String,
    val version: String,
    val title: String,
    val body: String,
    val sha256: String,
    @Serializable(InstantSerializer::class) val publishedAt: Instant? = null,
    val accepted: Boolean = false,
) {
    val id get() = "$key@$version"
}

/** The legal texts are written in a little Markdown: "## " headings, "- "
 *  lists and **bold**. Shown raw, a contract read "## Article 1 — Objet". */
object LegalText {
    sealed interface Block {
        val text: String
        data class Heading(override val text: String) : Block
        data class Bullet(override val text: String) : Block
        data class Paragraph(override val text: String) : Block
    }

    private val articleLine = Regex("^Article \\d+\\b")

    fun parse(markdown: String): List<Block> {
        val blocks = mutableListOf<Block>()
        val paragraph = mutableListOf<String>()
        fun flush() {
            if (paragraph.isNotEmpty()) blocks += Block.Paragraph(paragraph.joinToString(" "))
            paragraph.clear()
        }
        for (raw in markdown.split("\r\n", "\n", "\r")) {
            val line = raw.trim(' ', '\t')
            when {
                line.isEmpty() -> flush()
                line.startsWith("#") -> {
                    flush()
                    blocks += Block.Heading(line.dropWhile { it == '#' }.trim(' ', '\t'))
                }
                // texts written before the Markdown: "Article 3 — Durée" alone on its line
                articleLine.containsMatchIn(line) && line.length < 80 -> {
                    flush()
                    blocks += Block.Heading(line)
                }
                line.startsWith("- ") || line.startsWith("• ") -> {
                    flush()
                    blocks += Block.Bullet(line.drop(2))
                }
                else -> paragraph += line
            }
        }
        flush()
        return blocks
    }

    /** A run of text, bold or not: `**bold**` inline, as the texts use it. */
    data class Run(val text: String, val bold: Boolean)

    private val boldPattern = Regex("\\*\\*(.+?)\\*\\*")

    fun runs(text: String): List<Run> {
        val out = mutableListOf<Run>()
        var last = 0
        for (m in boldPattern.findAll(text)) {
            if (m.range.first > last) out += Run(text.substring(last, m.range.first), false)
            out += Run(m.groupValues[1], true)
            last = m.range.last + 1
        }
        if (last < text.length) out += Run(text.substring(last), false)
        return out
    }
}
