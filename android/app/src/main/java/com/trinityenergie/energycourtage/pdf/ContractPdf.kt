package com.trinityenergie.energycourtage.pdf

import android.graphics.Canvas
import android.graphics.pdf.PdfDocument
import com.trinityenergie.energycourtage.model.ApporteurContract
import com.trinityenergie.energycourtage.model.LegalDocument
import com.trinityenergie.energycourtage.model.LegalText
import com.trinityenergie.energycourtage.model.label
import java.io.ByteArrayOutputStream
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The demo's contract PDF (iOS DemoContractPDF): where there is no server to
 * file the real one, a plain rendering of the texts and the signature
 * certificate, nothing more. The real contract PDF is produced by the
 * contract-pdf function and downloaded.
 */
object ContractPdf {
    private const val PAGE_W = 595f
    private const val PAGE_H = 842f
    private const val MARGIN = 48f
    private const val CONTENT = PAGE_W - MARGIN * 2

    private val navy = hex(0x0A1F4A)
    private val text = hex(0x1C2333)
    private val meta = hex(0x5B6478)
    private val label = hex(0x6B7385)

    private val signedAt = DateTimeFormatter.ofPattern("dd.MM.yyyy 'à' HH:mm", Locale.FRANCE).withZone(ZoneId.systemDefault())

    fun renderDemo(contract: ApporteurContract, texts: List<LegalDocument>): ByteArray {
        val fonts = PdfFonts.load(null)
        val pdf = PdfDocument()
        try {
            val flow = Flow(pdf)
            fun body(size: Float = 10f, color: Int = text) = Ink(fonts.body, size, color)
            fun bold(size: Float = 10f, color: Int = text) = Ink(fonts.bold, size, color)

            flow.line("TRINITY ÉNERGIE — DÉMONSTRATION, SANS VALEUR CONTRACTUELLE", body(9f, meta))
            flow.y += 4
            flow.paragraph("Contrat d'apporteur d'affaires", bold(20f, navy), bold(20f, navy))
            flow.line("Réf. ${contract.reference} · ${contract.signerFullName}", body(9f, meta))
            flow.y += 10

            fun section(title: String?, markdown: String) {
                if (title != null) { flow.y += 18; flow.paragraph(title, bold(13f, navy), bold(13f, navy)); flow.y += 4 }
                for (block in LegalText.parse(markdown)) when (block) {
                    is LegalText.Block.Heading -> { flow.y += 12; flow.paragraph(block.text, bold(10.5f, navy), bold(10.5f, navy)); flow.y += 2 }
                    is LegalText.Block.Bullet -> { flow.paragraph("— " + block.text, body(), bold(), indent = 12f); flow.y += 6 }
                    is LegalText.Block.Paragraph -> { flow.paragraph(block.text, body(), bold()); flow.y += 6 }
                }
            }
            texts.firstOrNull { it.key == "contrat_apporteur" }?.let { section(null, it.body) }
            texts.firstOrNull { it.key == "mandat_facturation" }?.let { section("Annexe — ${it.title}", it.body) }

            flow.y += 18
            flow.paragraph("Certificat de signature électronique", bold(13f, navy), bold(13f, navy))
            flow.y += 6
            val rows = listOf(
                "SIGNATAIRE" to contract.signerFullName,
                "STATUT" to contract.businessStatus.label + (contract.companyName?.let { " — $it" } ?: ""),
                "DATE" to signedAt.format(contract.signedAt),
                "MÉTHODE" to "Code SMS vérifié · ${contract.otpPhone ?: ""}",
            )
            for ((k, v) in rows) {
                flow.keep(16f)
                Ink(fonts.bold, 8f, label, 0.5f).draw(flow.canvas, k, MARGIN, flow.y + 2)
                body().draw(flow.canvas, v, MARGIN + 90, flow.y)
                flow.y += 16
            }
            flow.finish()
            val out = ByteArrayOutputStream()
            pdf.writeTo(out)
            return out.toByteArray()
        } finally {
            pdf.close()
        }
    }

    private class Flow(val pdf: PdfDocument) {
        var y = MARGIN
        private var page = 0
        private var current: PdfDocument.Page? = null
        val canvas: Canvas
            get() {
                if (current == null) newPage()
                return current!!.canvas
            }

        fun newPage() {
            current?.let { pdf.finishPage(it) }
            page += 1
            current = pdf.startPage(PdfDocument.PageInfo.Builder(PAGE_W.toInt(), PAGE_H.toInt(), page).create())
            y = MARGIN
        }

        fun keep(h: Float) { if (current == null || y + h > PAGE_H - MARGIN) newPage() }

        fun finish() { if (current == null) newPage(); current?.let { pdf.finishPage(it) }; current = null }

        fun line(s: String, ink: Ink) {
            val h = ink.size * 1.45f
            keep(h)
            ink.draw(canvas, s, MARGIN, y)
            y += h
        }

        /** A paragraph with **bold** runs, wrapped word by word. */
        fun paragraph(markdown: String, plain: Ink, strong: Ink, indent: Float = 0f) {
            val h = plain.size * 1.45f
            val words = LegalText.runs(markdown).flatMap { run ->
                run.text.split(Regex("\\s+")).filter { it.isNotEmpty() }.map { it to run.bold }
            }
            val space = plain.width(" ")
            var x = MARGIN + indent
            keep(h)
            for ((word, isBold) in words) {
                val ink = if (isBold) strong else plain
                val w = ink.width(word)
                if (x > MARGIN + indent && x + w > MARGIN + CONTENT) { y += h; x = MARGIN + indent; keep(h) }
                ink.draw(canvas, word, x, y)
                x += w + space
            }
            y += h
        }
    }
}
