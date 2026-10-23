package com.trinityenergie.energycourtage.pdf

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import com.trinityenergie.energycourtage.model.InvoiceDocument
import com.trinityenergie.energycourtage.model.plainRate
import java.io.ByteArrayOutputStream
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Renders the invoice, or the credit note, as an A4 PDF -- a port of
 * Features/Invoices/InvoicePDF.swift, which mirrors
 * supabase/functions/_shared/invoice_pdf.ts, the copy retained for ten years.
 *
 * The PDF is a rendering of a document the database already fixed: what is
 * signed is `document_sha256`. So the page is free to lay itself out; what it
 * must not do is leave anything out -- both parties by their legal identity,
 * the "Autofacturation" mention, HT / TVA / TTC, the due date and the
 * late-payment terms.
 */
object InvoicePdf {
    /** A4 in points. */
    private const val PAGE_W = 595f
    private const val PAGE_H = 842f
    private const val MARGIN = 44f
    private const val CONTENT = PAGE_W - MARGIN * 2
    /** The footer sits below this line, measured from the bottom of the page. */
    private const val FOOTER_TOP = 58f
    /** The tracking of small capitals; wider splits words in the text layer. */
    private const val CAPS_KERN = 0.2f

    /** One colour and greys, the way a document from an accountant looks. */
    private object C {
        val navy = hex(0x0A1F4A)
        val mark = hex(0x3C8BFF)
        val text = hex(0x1C2333)
        val grey = hex(0x5B6478)
        val label = hex(0x6B7385)
        val faint = hex(0x8A93A6)
        val rule = hex(0xE3E7EF)
        val pending = hex(0xD5DAE3)
    }

    /** "FACTURE" or "AVOIR": a credit note has to say it is one. */
    fun title(doc: InvoiceDocument) = if (doc.isCreditNote) "AVOIR" else "FACTURE"

    /** "18.09.2026 à 12:00", in Paris time, where the parties are. */
    private val parisDateTime = DateTimeFormatter.ofPattern("dd.MM.yyyy 'à' HH:mm", Locale.FRANCE)
        .withZone(ZoneId.of("Europe/Paris"))

    /** Twice: the first pass only counts the pages, so that every footer can
     *  say "Page 1 / 2" -- a page cannot be revisited once it is done. */
    fun render(doc: InvoiceDocument, context: Context?): ByteArray {
        val fonts = PdfFonts.load(context)
        val total = pass(doc, fonts, 1).second
        return pass(doc, fonts, total).first
    }

    private fun pass(doc: InvoiceDocument, fonts: PdfFonts, totalPages: Int): Pair<ByteArray, Int> {
        val pdf = PdfDocument()
        try {
            val l = Layout(pdf, doc, fonts, totalPages)
            l.newPage(first = true)
            header(l); keyFacts(l); parties(l); lineItems(l); totals(l); mentions(l); signatures(l)
            l.finish()
            val out = ByteArrayOutputStream()
            pdf.writeTo(out)
            return out.toByteArray() to l.page
        } finally {
            pdf.close()
        }
    }

    // ------------------------------------------------------------------ layout

    /** A cursor down the page that starts a new one when it runs out of room.
     *  Every page gets the footer with its number and the fingerprint. */
    private class Layout(val pdf: PdfDocument, val doc: InvoiceDocument, val f: PdfFonts, val totalPages: Int) {
        var y = 0f
        var page = 0
        private var current: PdfDocument.Page? = null
        val canvas: Canvas get() = current!!.canvas
        val bottom get() = PAGE_H - FOOTER_TOP - 14

        fun body(size: Float, color: Int = C.text, kern: Float = 0f, italic: Boolean = false) = Ink(f.body, size, color, kern, italic)
        fun bold(size: Float, color: Int = C.text, kern: Float = 0f) = Ink(f.bold, size, color, kern)
        fun display(size: Float, color: Int = C.navy, kern: Float = 0f) = Ink(f.display, size, color, kern)

        fun newPage(first: Boolean = false) {
            current?.let { pdf.finishPage(it) }
            page += 1
            current = pdf.startPage(PdfDocument.PageInfo.Builder(PAGE_W.toInt(), PAGE_H.toInt(), page).create())
            y = MARGIN
            footer()
            if (!first) {
                bold(7.5f, C.faint, 0.4f).draw(canvas, "${title(doc)} N° ${doc.number} — SUITE", MARGIN, y)
                y += 26
            }
        }

        fun finish() { current?.let { pdf.finishPage(it) }; current = null }

        fun keep(height: Float) { if (y + height > bottom) newPage() }

        fun text(s: String, ink: Ink, x: Float = MARGIN, width: Float = CONTENT, leading: Float? = null) {
            val lineHeight = leading ?: (ink.size * 1.45f)
            for (line in ink.wrap(s, width)) {
                keep(lineHeight)
                ink.draw(canvas, line, x, y + (lineHeight - ink.lineHeight) / 2)
                y += lineHeight
            }
        }

        /** A small letter-spaced section heading with a hairline after it. */
        fun heading(label: String) {
            keep(40f)
            y += 6
            val ink = bold(6.8f, C.label, CAPS_KERN)
            ink.draw(canvas, label, MARGIN, y)
            val w = ink.width(label)
            canvas.rule(MARGIN + w + 10, y + 4.5f, CONTENT - w - 10, C.rule)
            y += 16
        }

        private fun footer() {
            val line = PAGE_H - FOOTER_TOP
            canvas.rule(MARGIN, line, CONTENT, C.rule)
            val ink = body(7.2f, C.grey)
            ink.draw(canvas, "${if (doc.isCreditNote) "Avoir" else "Facture"} ${doc.number} · Trinity Énergie", MARGIN, line + 8)
            ink.drawRight(canvas, "Page $page / $totalPages", PAGE_W - MARGIN, line + 8)
            // the digest apart from its label, in groups of eight, not tracked,
            // so a filed copy stays searchable for its own fingerprint
            val label = "Empreinte SHA-256 du document signé : "
            val labelInk = body(6.6f, C.faint)
            labelInk.draw(canvas, label, MARGIN, line + 22)
            bold(6.6f, C.grey).draw(canvas, PdfText.grouped(doc.documentSha256), MARGIN + labelInk.width(label), line + 22)
        }
    }

    // -------------------------------------------------------------- the page

    /** The mark and the name on the left; on the right what the document is,
     *  its number, and that it is self-billed. */
    private fun header(l: Layout) {
        val doc = l.doc
        val top = l.y
        val right = PAGE_W - MARGIN
        val c = l.canvas
        c.trinityMark(MARGIN, top + 1, 20f, C.navy, C.mark)
        l.display(10f, C.navy, 2.4f).draw(c, "TRINITY ÉNERGIE", MARGIN + 29, top + 5)
        doc.customer?.let { l.body(8f, C.grey).draw(c, "${it.address}, ${it.postalCode} ${it.city}", MARGIN, top + 28) }

        l.display(20f, C.navy, 1.5f).drawRight(c, title(doc), right, top - 3)
        l.bold(10f, C.navy).drawRight(c, "N° ${doc.number}", right, top + 25)
        var y = top + 39
        l.body(8f, C.grey).drawRight(c, if (doc.isCreditNote) "Avoir en autofacturation" else "Autofacturation", right, y)
        val original = doc.correctsNumber
        if (doc.isCreditNote && original != null) {
            y += 12
            l.body(8f, C.grey).drawRight(c, "Avoir sur la facture n° $original", right, y)
        }
        l.y = y + 24
        c.rule(MARGIN, l.y, CONTENT, C.rule)
        l.y += 14
    }

    /** When it was issued, when it is due, how it is paid, how much. */
    private fun keyFacts(l: Layout) {
        val doc = l.doc
        val facts = listOf(
            "DATE D'ÉMISSION" to doc.issuedOn,
            "ÉCHÉANCE" to (doc.dueOn ?: "À réception"),
            "RÈGLEMENT" to doc.paymentMethod,
            (if (doc.isCreditNote) "MONTANT À DÉDUIRE" else "MONTANT TTC") to PdfText.money(doc.amount.ttc, doc.amount.currency),
        )
        val column = CONTENT / 4
        val labelInk = l.bold(6.6f, C.label, CAPS_KERN)
        val valueInk = l.bold(10.5f, C.navy)
        facts.forEachIndexed { i, (label, value) ->
            if (i == facts.lastIndex) {
                labelInk.drawRight(l.canvas, label, MARGIN + CONTENT, l.y)
                valueInk.drawRight(l.canvas, value, MARGIN + CONTENT, l.y + 12)
            } else {
                val x = MARGIN + i * column
                labelInk.draw(l.canvas, label, x, l.y)
                valueInk.draw(l.canvas, value, x, l.y + 12)
            }
        }
        l.y += 34
        l.canvas.rule(MARGIN, l.y, CONTENT, C.rule)
        l.y += 16
    }

    internal fun supplierLines(doc: InvoiceDocument): List<String> {
        val p = doc.apporteur
        val town = listOfNotNull(p.postalCode, p.city).filter { it.isNotEmpty() }.joinToString(" ")
        return listOfNotNull(p.company, p.legalForm, p.address, town, p.siret?.let { "SIRET $it" }, p.vatNumber?.let { "TVA $it" })
            .filter { it.isNotBlank() }
    }

    internal fun customerLines(doc: InvoiceDocument): Pair<String, List<String>> {
        // issued before the company's legal identity was recorded
        val c = doc.customer ?: return (doc.issuer.company ?: doc.issuer.name) to listOfNotNull(doc.issuer.city)
        val form = listOfNotNull(c.legalForm, c.shareCapital?.let { "au capital de $it" }).joinToString(" ")
        return c.legalName to listOf(
            form, c.address, "${c.postalCode} ${c.city}",
            "SIREN ${c.siren}" + (c.rcsCity?.let { " · RCS $it" } ?: ""),
            c.vatNumber?.let { "TVA $it" } ?: "",
        ).filter { it.isNotEmpty() }
    }

    /** The two parties side by side, as columns of text rather than cards. */
    private fun parties(l: Layout) {
        val doc = l.doc
        val gap = 28f
        val w = (CONTENT - gap) / 2
        val leading = 12.2f
        val nameInk = l.bold(10.5f, C.navy)
        val lineInk = l.body(8.6f, C.grey)
        val customer = customerLines(doc)
        val columns = listOf(
            Triple("FOURNISSEUR · APPORTEUR", doc.apporteur.name, supplierLines(doc)),
            Triple("CLIENT", customer.first, customer.second),
        )
        fun measure(c: Triple<String, String, List<String>>) =
            13 + nameInk.wrap(c.second, w).size * 14 + c.third.sumOf { lineInk.wrap(it, w).size } * leading
        val h = columns.maxOf { measure(it) }
        l.keep(h)
        columns.forEachIndexed { i, (label, name, lines) ->
            val x = MARGIN + i * (w + gap)
            l.bold(6.6f, C.label, CAPS_KERN).draw(l.canvas, label, x, l.y)
            var y = l.y + 13
            for (line in nameInk.wrap(name, w)) { nameInk.draw(l.canvas, line, x, y); y += 14 }
            for (text in lines) for (line in lineInk.wrap(text, w)) { lineInk.draw(l.canvas, line, x, y); y += leading }
        }
        l.y += h + 24
    }

    /** Désignation · Qté · Prix unitaire HT · Montant HT, under a navy rule. */
    private fun lineItems(l: Layout) {
        val doc = l.doc
        val totalRight = MARGIN + CONTENT
        val unitRight = totalRight - 96
        val qtyRight = unitRight - 96
        val designationWidth = qtyRight - MARGIN - 40
        val head = l.bold(6.6f, C.label, CAPS_KERN)

        fun headerRow() {
            l.keep(60f)
            head.draw(l.canvas, "DÉSIGNATION", MARGIN, l.y)
            head.drawRight(l.canvas, "QTÉ", qtyRight, l.y)
            head.drawRight(l.canvas, "PRIX UNIT. HT", unitRight, l.y)
            head.drawRight(l.canvas, "MONTANT HT", totalRight, l.y)
            l.canvas.rule(MARGIN, l.y + 13, CONTENT, C.navy, 0.9f)
            l.y += 22
        }
        headerRow()

        val amount = PdfText.money(doc.amount.ht, doc.amount.currency)
        val row = l.bold(9.5f, C.navy)
        val plain = l.body(9.5f, C.text)
        row.wrap(doc.attestation.prestation, designationWidth).forEachIndexed { i, line ->
            if (l.y + 13.5f > l.bottom) { l.newPage(); headerRow() }
            row.draw(l.canvas, line, MARGIN, l.y)
            if (i == 0) {
                plain.drawRight(l.canvas, "1", qtyRight, l.y)
                plain.drawRight(l.canvas, amount, unitRight, l.y)
                plain.drawRight(l.canvas, amount, totalRight, l.y)
            }
            l.y += 13.5f
        }
        l.text("Mise en relation avec ${doc.attestation.avec}, intervenue le ${doc.attestation.intervenueLe}.",
            l.body(8f, C.grey), width = designationWidth)
        l.y += 8
        l.canvas.rule(MARGIN, l.y, CONTENT, C.rule)
        l.y += 14
    }

    /** Totals flush right, the last under a navy rule; payment terms on the left. */
    private fun totals(l: Layout) {
        val doc = l.doc
        val cur = doc.amount.currency
        val w = 200f
        val x = MARGIN + CONTENT - w
        val right = MARGIN + CONTENT
        val rows = listOf(
            "Total HT" to PdfText.money(doc.amount.ht, cur),
            "TVA (${doc.amount.vatRate.plainRate().replace(".", ",")} %)" to PdfText.money(doc.amount.vat, cur),
        )
        val termInk = l.body(8f, C.grey)
        val leftWidth = CONTENT - w - 40
        val terms = listOf(
            "Règlement : ${doc.paymentMethod}" + (doc.dueOn?.let { ", au plus tard le $it" } ?: "") + ".",
            "Fait à ${doc.place}, le ${doc.issuedOn}.",
        ).flatMap { termInk.wrap(it, leftWidth) }
        l.keep(maxOf(rows.size * 16f + 34, terms.size * 11.5f))
        val top = l.y

        var ty = top
        for (line in terms) { termInk.draw(l.canvas, line, MARGIN, ty); ty += 11.5f }

        var y = top
        val rowInk = l.body(9f, C.grey)
        for ((label, value) in rows) {
            rowInk.draw(l.canvas, label, x, y)
            rowInk.drawRight(l.canvas, value, right, y)
            y += 16
        }
        y += 3
        l.canvas.rule(x, y, w, C.navy, 1.2f)
        y += 7
        l.bold(10.5f, C.navy).draw(l.canvas, if (doc.isCreditNote) "Total TTC à déduire" else "Total TTC", x, y + 1)
        l.display(13f, C.navy).drawRight(l.canvas, PdfText.money(doc.amount.ttc, cur), right, y - 1)
        l.y = maxOf(y + 22, ty) + 14
    }

    /** The self-billing sentence, the VAT regime and the late-payment terms
     *  under one heading, then the attestation. */
    private fun mentions(l: Layout) {
        val doc = l.doc
        l.heading("MENTIONS LÉGALES")
        val small = l.body(8f, C.grey)
        doc.selfBillingMention?.let { l.text(it, small) }
        l.text(doc.legalMentions, small)
        doc.latePaymentMention?.let { l.text(it, small) }
        if (!doc.isCreditNote) {
            l.y += 6
            l.heading("ATTESTATION")
            l.text(attestationSentence(doc), l.body(8.6f))
        }
        doc.taxNotice?.let {
            l.y += 6
            l.text(it, l.body(7.8f, C.faint))
        }
        l.y += 4
    }

    fun attestationSentence(doc: InvoiceDocument) =
        "Je soussigné(e) ${doc.attestation.soussigne} atteste avoir mis en relation " +
            "${doc.attestation.misEnRelation ?: "la société"} avec ${doc.attestation.avec} " +
            "pour la prestation ci-dessus."

    /** One column per party under a rule -- navy once signed, pale while
     *  awaited -- with the state said in words. */
    private fun signatures(l: Layout) {
        val doc = l.doc
        val gap = 28f
        val w = (CONTENT - gap) / 2
        val h = 74f
        l.keep(h + 24)   // the heading stays with its columns
        l.heading("SIGNATURES ÉLECTRONIQUES")
        l.y += 2
        doc.signatures.take(2).forEachIndexed { i, s ->
            val x = MARGIN + i * (w + gap)
            val c = l.canvas
            c.rule(x, l.y, w, if (s.signed) C.navy else C.pending, 1.2f)
            l.bold(6.6f, C.label, CAPS_KERN).draw(c, if (s.role == "apporteur") "L'APPORTEUR" else "L'ENTREPRISE", x, l.y + 8)
            l.bold(10.5f, C.navy).draw(c, s.name, x, l.y + 20)
            val statusY = l.y + 38
            if (s.signed) {
                tick(c, x, statusY + 1.5f, C.navy)
                l.bold(8f, C.navy).draw(c,
                    s.signedAt?.let { "Signé électroniquement le ${parisDateTime.format(it)}" } ?: "Signé électroniquement",
                    x + 11, statusY)
                val evidence = listOf(
                    if (s.smsVerified == true) "Code SMS vérifié · ${s.smsPhone ?: ""}" else "Session authentifiée",
                    "Heure de Paris · art. 1367 du Code civil",
                )
                evidence.forEachIndexed { j, line -> l.body(7.8f, C.grey).draw(c, line, x + 11, statusY + 12 + j * 11) }
            } else {
                ring(c, x, statusY + 1.5f, C.faint)
                l.body(8f, C.grey).draw(c, "En attente de signature", x + 11, statusY)
            }
        }
        l.y += h
    }

    /** A check mark drawn rather than typed: the brand faces have no ✓. */
    private fun tick(c: Canvas, x: Float, y: Float, color: Int) {
        val path = Path().apply { moveTo(x, y + 3.4f); lineTo(x + 2.4f, y + 5.8f); lineTo(x + 6.6f, y + 0.6f) }
        c.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color; style = Paint.Style.STROKE; strokeWidth = 1.1f
            strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
        })
    }

    /** An empty circle: a signature still to come. */
    private fun ring(c: Canvas, x: Float, y: Float, color: Int) {
        c.drawOval(RectF(x + 0.5f, y, x + 6.5f, y + 6f), Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color; style = Paint.Style.STROKE; strokeWidth = 0.8f
        })
    }
}
