import Foundation
#if canImport(UIKit)
import UIKit
import CoreText
#endif

/// Renders the invoice, or the credit note, as a PDF.
///
/// The PDF is a *rendering* of a document the database already fixed: what is
/// signed is `document_sha256`, the digest of `invoice_canonical_text()`. That
/// is deliberate — asking two devices to reproduce identical PDF bytes would
/// make the signature break the first time either side reflowed a line. So
/// this file is free to lay the page out for readability, and the legal
/// binding is unaffected by how it looks.
///
/// What it must not do is leave anything out. The page carries every mention
/// an invoice needs (art. 242 nonies A ann. II CGI; art. L441-9 and L441-10 du
/// Code de commerce): both parties by their legal identity, the
/// "Autofacturation" mention, HT / TVA / TTC, the due date and the
/// late-payment terms.
///
/// The design mirrors supabase/functions/_shared/invoice_pdf.ts, which renders
/// the copy that is retained for ten years: what a signer previews here is what
/// is filed.
public enum InvoicePDF {

    /// A4 at 72dpi, the unit Core Graphics works in.
    static let pageSize = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 44
    static var content: CGFloat { pageSize.width - margin * 2 }
    /// The footer sits below this line, measured from the bottom of the page.
    static let footerTop: CGFloat = 58

    public static func render(_ doc: InvoiceDocument) -> Data {
        #if canImport(UIKit)
        // Twice: the first pass only counts the pages, so that every footer
        // can say "Page 1 / 2" -- a page cannot be revisited once it is done.
        var total = 1
        _ = pass(doc, totalPages: 1) { total = $0 }
        return pass(doc, totalPages: total) { _ in }
        #else
        // The renderer is UIKit-only. On any other platform the app has no
        // screen to show it on either, so an empty document is honest.
        return Data()
        #endif
    }

    /// "FACTURE" or "AVOIR": a credit note has to say it is one.
    static func title(for doc: InvoiceDocument) -> String {
        doc.isCreditNote ? "AVOIR" : "FACTURE"
    }

    /// "300.00" from the server, "300,00 €" on the page, thousands spaced:
    /// the database sends amounts in a fixed machine format so nothing is lost
    /// to a locale, and the French way of writing them is applied only here.
    static func money(_ amount: String, _ currency: String) -> String {
        let symbol = currency == "EUR" ? "€" : currency
        let parts = amount.split(separator: ".", maxSplits: 1).map(String.init)
        var whole = parts.first ?? amount
        let sign = whole.hasPrefix("-") ? "-" : ""
        whole = whole.replacingOccurrences(of: "-", with: "")
        var grouped = ""
        for (i, ch) in whole.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { grouped.append(" ") }
            grouped.append(ch)
        }
        let cents = parts.count > 1 ? parts[1] : "00"
        return "\(sign)\(String(grouped.reversed())),\(cents)\u{00A0}\(symbol)"
    }

    /// The digest in groups of eight, readable aloud if it ever has to be.
    static func grouped(_ digest: String?) -> String {
        guard let digest else { return "document non scellé" }
        var out = ""
        for (i, ch) in digest.enumerated() {
            if i > 0 && i % 8 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    #if canImport(UIKit)

    // MARK: - Look

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// One colour and greys, the way a document from an accountant looks:
    /// white paper, navy for what matters, grey for the rest, hairlines for
    /// structure. The mark's blue appears in the mark and nowhere else -- no
    /// tinted tiles, no coloured pills -- so the page prints as well in black
    /// and white as it reads on screen.
    private enum Ink {
        /// Titles, figures, names, and the rules that carry weight.
        static let navy = color(0x0A1F4A)
        /// The inner triangle of the mark.
        static let mark = color(0x3C8BFF)
        static let text = color(0x1C2333)
        static let grey = color(0x5B6478)
        /// Small capitals: labels and section headings.
        static let label = color(0x6B7385)
        static let faint = color(0x8A93A6)
        static let rule = color(0xE3E7EF)
        /// The rule over a signature still awaited.
        static let pending = color(0xD5DAE3)
    }

    /// Manrope and Sora at a given weight: the app's bundled faces are
    /// variable, so the weight is set on the axis rather than by name.
    private static func face(_ family: String, _ weight: CGFloat, _ size: CGFloat,
                             fallback: UIFont.Weight) -> UIFont {
        Theme.registerFonts()
        let wght = 0x77676874   // 'wght'
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight]
        ])
        let font = UIFont(descriptor: descriptor, size: size)
        return font.familyName == family ? font : .systemFont(ofSize: size, weight: fallback)
    }

    private struct Fonts {
        let size: (CGFloat) -> (body: UIFont, bold: UIFont, display: UIFont)
        init() {
            size = { s in
                (face("Manrope", 400, s, fallback: .regular),
                 face("Manrope", 700, s, fallback: .bold),
                 face("Sora", 600, s, fallback: .semibold))
            }
        }
        func body(_ s: CGFloat) -> UIFont { size(s).body }
        func bold(_ s: CGFloat) -> UIFont { size(s).bold }
        func display(_ s: CGFloat) -> UIFont { size(s).display }
    }

    /// The tracking of small capitals. Any wider and the text layer splits
    /// words ("AT TESTATION"), which a search of the filed copy would miss.
    private static let capsKern: CGFloat = 0.2

    private static func attrs(_ font: UIFont, _ color: UIColor, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        // no ligatures: an "ff" drawn as one glyph reads back as nothing, and
        // "affaires" would not be found by a search of the filed document
        [.font: font, .foregroundColor: color, .kern: kern, .ligature: 0]
    }

    private static func width(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((s as NSString).size(withAttributes: a).width)
    }

    /// Draws one line with its top at `y`.
    private static func draw(_ s: String, x: CGFloat, y: CGFloat, _ a: [NSAttributedString.Key: Any]) {
        (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: a)
    }

    /// Draws one line ending at `right`.
    private static func drawRight(_ s: String, right: CGFloat, y: CGFloat, _ a: [NSAttributedString.Key: Any]) {
        draw(s, x: right - width(s, a), y: y, a)
    }

    /// Lines that fit `maxWidth`, keeping explicit newlines.
    private static func wrap(_ text: String, _ a: [NSAttributedString.Key: Any], _ maxWidth: CGFloat) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(whereSeparator: \.isWhitespace).map(String.init) {
                let candidate = line.isEmpty ? word : "\(line) \(word)"
                if width(candidate, a) <= maxWidth {
                    line = candidate
                } else {
                    if !line.isEmpty { lines.append(line) }
                    line = word
                }
            }
            lines.append(line)
        }
        return lines
    }

    /// A horizontal rule from `x` to `x + length`.
    private static func rule(x: CGFloat = margin, y: CGFloat, length: CGFloat = content,
                             color: UIColor = Ink.rule, width: CGFloat = 0.5) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + length, y: y))
        path.lineWidth = width
        color.setStroke(); path.stroke()
    }

    /// The mark: an open triangle and a solid one inside (the site's SVG, 24×22).
    private static func logo(at origin: CGPoint, size: CGFloat, line: UIColor) {
        let s = size / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        let outer = UIBezierPath()
        outer.move(to: p(12, 1.25)); outer.addLine(to: p(22.5, 20.75)); outer.addLine(to: p(1.5, 20.75)); outer.close()
        outer.lineWidth = 1.8 * s
        outer.lineJoinStyle = .round
        line.setStroke(); outer.stroke()
        let inner = UIBezierPath()
        inner.move(to: p(12, 8.75)); inner.addLine(to: p(16.5, 17)); inner.addLine(to: p(7.5, 17)); inner.close()
        Ink.mark.setFill(); inner.fill()
    }

    // MARK: - Layout

    /// A cursor down the page that starts a new one when it runs out of room,
    /// so a long prestation label cannot spill off the bottom. Every page gets
    /// the footer with its number and the document's fingerprint.
    private struct Layout {
        let context: UIGraphicsPDFRendererContext
        let doc: InvoiceDocument
        let fonts: Fonts
        let totalPages: Int
        var y: CGFloat = 0
        var page = 0

        var bottom: CGFloat { pageSize.height - footerTop - 14 }

        mutating func newPage(first: Bool = false) {
            context.beginPage()
            page += 1
            y = margin
            footer()
            if !first {
                draw("\(title(for: doc)) N° \(doc.number) — SUITE", x: margin, y: y,
                     attrs(fonts.bold(7.5), Ink.faint, kern: 0.4))
                y += 26
            }
        }

        mutating func keep(_ height: CGFloat) {
            if y + height > bottom { newPage() }
        }

        mutating func space(_ points: CGFloat) { y += points }

        mutating func text(_ string: String, font: UIFont, color: UIColor = Ink.text,
                           x: CGFloat = margin, width: CGFloat = content, leading: CGFloat? = nil) {
            let a = attrs(font, color)
            let lineHeight = leading ?? font.pointSize * 1.45
            for line in wrap(string, a, width) {
                keep(lineHeight)
                InvoicePDF.draw(line, x: x, y: y + (lineHeight - font.lineHeight) / 2, a)
                y += lineHeight
            }
        }

        /// A small letter-spaced section heading with a hairline after it.
        mutating func heading(_ label: String) {
            keep(40)
            y += 6
            let a = attrs(fonts.bold(6.8), Ink.label, kern: capsKern)
            draw(label, x: margin, y: y, a)
            let w = width(label, a)
            InvoicePDF.rule(x: margin + w + 10, y: y + 4.5, length: content - w - 10)
            y += 16
        }

        func footer() {
            let line = pageSize.height - footerTop
            rule(y: line)
            let a = attrs(fonts.body(7.2), Ink.grey)
            draw("\(doc.isCreditNote ? "Avoir" : "Facture") \(doc.number) · Trinity Énergie",
                 x: margin, y: line + 8, a)
            drawRight("Page \(page) / \(totalPages)", right: pageSize.width - margin, y: line + 8, a)
            // The digest apart from its label, in groups of eight that can be
            // read out and compared. Not letter-spaced: tracking made the
            // text layer read "f be79519", and a filed copy has to be
            // searchable for its own fingerprint.
            let label = "Empreinte SHA-256 du document signé : "
            let labelAttrs = attrs(fonts.body(6.6), Ink.faint)
            draw(label, x: margin, y: line + 22, labelAttrs)
            draw(grouped(doc.documentSha256), x: margin + width(label, labelAttrs), y: line + 22,
                 attrs(fonts.bold(6.6), Ink.grey))
        }
    }

    // MARK: - The page

    private static func pass(_ doc: InvoiceDocument, totalPages: Int, pages: (Int) -> Void) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize),
                                             format: metadata(for: doc))
        return renderer.pdfData { context in
            var L = Layout(context: context, doc: doc, fonts: Fonts(), totalPages: totalPages)
            L.newPage(first: true)
            header(&L)
            keyFacts(&L)
            parties(&L)
            lineItems(&L)
            totals(&L)
            mentions(&L)
            signatures(&L)
            pages(L.page)
        }
    }

    private static func metadata(for doc: InvoiceDocument) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        let customer = doc.customer?.legalName ?? doc.issuer.company ?? doc.issuer.name
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(doc.isCreditNote ? "Avoir" : "Facture") \(doc.number)",
            kCGPDFContextAuthor as String: doc.apporteur.name,
            kCGPDFContextCreator as String: customer,
            // Traceability back to what was signed, without which a saved file
            // cannot be matched to its invoice.
            kCGPDFContextSubject as String:
                "Autofacturation — document \(doc.documentSha256 ?? "non scellé")"
        ]
        return format
    }

    /// The mark and the name on the left; on the right what the document is,
    /// its number, and that it is self-billed -- a mention the law requires,
    /// so it sits where the eye looks first.
    private static func header(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let top = L.y, right = pageSize.width - margin
        logo(at: CGPoint(x: margin, y: top + 1), size: 20, line: Ink.navy)
        draw("TRINITY ÉNERGIE", x: margin + 29, y: top + 5, attrs(f.display(10), Ink.navy, kern: 2.4))
        if let c = doc.customer {
            draw("\(c.address), \(c.postalCode) \(c.city)", x: margin, y: top + 28, attrs(f.body(8), Ink.grey))
        }

        drawRight(title(for: doc), right: right, y: top - 3, attrs(f.display(20), Ink.navy, kern: 1.5))
        drawRight("N° \(doc.number)", right: right, y: top + 25, attrs(f.bold(10), Ink.navy))
        var y = top + 39
        drawRight(doc.isCreditNote ? "Avoir en autofacturation" : "Autofacturation",
                  right: right, y: y, attrs(f.body(8), Ink.grey))
        if doc.isCreditNote, let original = doc.correctsNumber {
            y += 12
            drawRight("Avoir sur la facture n° \(original)", right: right, y: y, attrs(f.body(8), Ink.grey))
        }
        L.y = y + 24
        rule(y: L.y)
        L.y += 14
    }

    /// When it was issued, when it is due, how it is paid, how much: four
    /// facts in one row, all in the same voice. The amount is not singled out
    /// here; the totals below are where it carries weight.
    private static func keyFacts(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let facts: [(String, String)] = [
            ("DATE D'ÉMISSION", doc.issuedOn),
            ("ÉCHÉANCE", doc.dueOn ?? "À réception"),
            ("RÈGLEMENT", doc.paymentMethod),
            (doc.isCreditNote ? "MONTANT À DÉDUIRE" : "MONTANT TTC", money(doc.amount.ttc, doc.amount.currency))
        ]
        let column = content / 4
        let labelAttrs = attrs(f.bold(6.6), Ink.label, kern: capsKern)
        let valueAttrs = attrs(f.bold(10.5), Ink.navy)
        for (i, fact) in facts.enumerated() {
            if i == facts.count - 1 {
                drawRight(fact.0, right: margin + content, y: L.y, labelAttrs)
                drawRight(fact.1, right: margin + content, y: L.y + 12, valueAttrs)
            } else {
                let x = margin + CGFloat(i) * column
                draw(fact.0, x: x, y: L.y, labelAttrs)
                draw(fact.1, x: x, y: L.y + 12, valueAttrs)
            }
        }
        L.y += 34
        rule(y: L.y)
        L.y += 16
    }

    private static func supplierLines(_ doc: InvoiceDocument) -> [String] {
        let p = doc.apporteur
        let town = [p.postalCode, p.city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return [p.company, p.legalForm, p.address, town,
                p.siret.map { "SIRET \($0)" }, p.vatNumber.map { "TVA \($0)" }]
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func customerLines(_ doc: InvoiceDocument) -> (String, [String]) {
        guard let c = doc.customer else {
            // issued before the company's legal identity was recorded
            return (doc.issuer.company ?? doc.issuer.name, [doc.issuer.city].compactMap { $0 })
        }
        let form = [c.legalForm, c.shareCapital.map { "au capital de \($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        return (c.legalName, [form, c.address, "\(c.postalCode) \(c.city)",
                              "SIREN \(c.siren)" + (c.rcsCity.map { " · RCS \($0)" } ?? ""),
                              c.vatNumber.map { "TVA \($0)" } ?? ""].filter { !$0.isEmpty })
    }

    /// The two parties side by side, as columns of text rather than cards.
    private static func parties(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let gap: CGFloat = 28, w = (content - gap) / 2, leading: CGFloat = 12.2
        let nameAttrs = attrs(f.bold(10.5), Ink.navy)
        let lineAttrs = attrs(f.body(8.6), Ink.grey)
        let customer = customerLines(doc)
        let columns: [(String, String, [String])] = [
            ("FOURNISSEUR · APPORTEUR", doc.apporteur.name, supplierLines(doc)),
            ("CLIENT", customer.0, customer.1)
        ]
        func measure(_ c: (String, String, [String])) -> CGFloat {
            13 + CGFloat(wrap(c.1, nameAttrs, w).count) * 14
                + CGFloat(c.2.reduce(0) { $0 + wrap($1, lineAttrs, w).count }) * leading
        }
        let h = columns.map(measure).max() ?? 0
        L.keep(h)
        for (i, column) in columns.enumerated() {
            let x = margin + CGFloat(i) * (w + gap)
            draw(column.0, x: x, y: L.y, attrs(f.bold(6.6), Ink.label, kern: capsKern))
            var y = L.y + 13
            for line in wrap(column.1, nameAttrs, w) { draw(line, x: x, y: y, nameAttrs); y += 14 }
            for text in column.2 {
                for line in wrap(text, lineAttrs, w) { draw(line, x: x, y: y, lineAttrs); y += leading }
            }
        }
        L.y += h + 24
    }

    /// Désignation · Qté · Prix unitaire HT · Montant HT, under a navy rule.
    private static func lineItems(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let totalRight = margin + content, unitRight = totalRight - 96, qtyRight = unitRight - 96
        let designationWidth = qtyRight - margin - 40
        let headAttrs = attrs(f.bold(6.6), Ink.label, kern: capsKern)

        func headerRow(_ L: inout Layout) {
            L.keep(60)
            draw("DÉSIGNATION", x: margin, y: L.y, headAttrs)
            drawRight("QTÉ", right: qtyRight, y: L.y, headAttrs)
            drawRight("PRIX UNIT. HT", right: unitRight, y: L.y, headAttrs)
            drawRight("MONTANT HT", right: totalRight, y: L.y, headAttrs)
            rule(y: L.y + 13, color: Ink.navy, width: 0.9)
            L.y += 22
        }
        headerRow(&L)

        let amount = money(doc.amount.ht, doc.amount.currency)
        let rowAttrs = attrs(f.bold(9.5), Ink.navy)
        let plain = attrs(f.body(9.5), Ink.text)
        for (i, line) in wrap(doc.attestation.prestation, rowAttrs, designationWidth).enumerated() {
            if L.y + 13.5 > L.bottom { L.newPage(); headerRow(&L) }
            draw(line, x: margin, y: L.y, rowAttrs)
            if i == 0 {
                drawRight("1", right: qtyRight, y: L.y, plain)
                drawRight(amount, right: unitRight, y: L.y, plain)
                drawRight(amount, right: totalRight, y: L.y, plain)
            }
            L.y += 13.5
        }
        L.text("Mise en relation avec \(doc.attestation.avec), intervenue le \(doc.attestation.intervenueLe).",
               font: f.body(8), color: Ink.grey, width: designationWidth)
        L.y += 8
        rule(y: L.y)
        L.y += 14
    }

    /// Totals flush right, the last under a navy rule; payment terms on the left.
    private static func totals(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts, cur = doc.amount.currency
        let w: CGFloat = 200, x = margin + content - w, right = margin + content
        let rows = [("Total HT", money(doc.amount.ht, cur)),
                    ("TVA (\((doc.amount.vatRate as NSDecimalNumber).stringValue.replacingOccurrences(of: ".", with: ",")) %)",
                     money(doc.amount.vat, cur))]
        let termAttrs = attrs(f.body(8), Ink.grey)
        let leftWidth = content - w - 40
        let terms = ["Règlement : \(doc.paymentMethod)" + (doc.dueOn.map { ", au plus tard le \($0)" } ?? "") + ".",
                     "Fait à \(doc.place), le \(doc.issuedOn)."].flatMap { wrap($0, termAttrs, leftWidth) }
        L.keep(max(CGFloat(rows.count) * 16 + 34, CGFloat(terms.count) * 11.5))
        let top = L.y

        var ty = top
        for line in terms { draw(line, x: margin, y: ty, termAttrs); ty += 11.5 }

        var y = top
        for (label, value) in rows {
            draw(label, x: x, y: y, attrs(f.body(9), Ink.grey))
            drawRight(value, right: right, y: y, attrs(f.body(9), Ink.grey))
            y += 16
        }
        y += 3
        rule(x: x, y: y, length: w, color: Ink.navy, width: 1.2)
        y += 7
        draw(doc.isCreditNote ? "Total TTC à déduire" : "Total TTC", x: x, y: y + 1, attrs(f.bold(10.5), Ink.navy))
        drawRight(money(doc.amount.ttc, cur), right: right, y: y - 1, attrs(f.display(13), Ink.navy))
        L.y = max(y + 22, ty) + 14
    }

    /// The self-billing sentence with the article that allows it, the VAT
    /// regime and the late-payment terms: plain text under one heading, as an
    /// accountant would set them, rather than a highlighted box.
    private static func mentions(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        L.heading("MENTIONS LÉGALES")
        if let selfBilling = doc.selfBillingMention { L.text(selfBilling, font: f.body(8), color: Ink.grey) }
        L.text(doc.legalMentions, font: f.body(8), color: Ink.grey)
        if let late = doc.latePaymentMention { L.text(late, font: f.body(8), color: Ink.grey) }
        if !doc.isCreditNote {
            L.space(6)
            L.heading("ATTESTATION")
            L.text("Je soussigné(e) \(doc.attestation.soussigne) atteste avoir mis en relation "
                   + "\(doc.attestation.misEnRelation ?? "la société") avec \(doc.attestation.avec) "
                   + "pour la prestation ci-dessus.", font: f.body(8.6))
        }
        if let notice = doc.taxNotice {
            L.space(6)
            L.text(notice, font: f.body(7.8), color: Ink.faint)
        }
        L.space(4)
    }

    /// One column per party under a rule -- navy once signed, pale while
    /// awaited -- with the state said in words rather than shown as a pill.
    private static func signatures(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let gap: CGFloat = 28, w = (content - gap) / 2, h: CGFloat = 74
        L.keep(h + 24)   // the heading stays with its columns
        L.heading("SIGNATURES ÉLECTRONIQUES")
        L.y += 2
        for (i, s) in doc.signatures.prefix(2).enumerated() {
            let x = margin + CGFloat(i) * (w + gap)
            rule(x: x, y: L.y, length: w, color: s.signed ? Ink.navy : Ink.pending, width: 1.2)
            draw(s.role == "apporteur" ? "L'APPORTEUR" : "L'ENTREPRISE", x: x, y: L.y + 8,
                 attrs(f.bold(6.6), Ink.label, kern: capsKern))
            draw(s.name, x: x, y: L.y + 20, attrs(f.bold(10.5), Ink.navy))

            let statusY = L.y + 38
            if s.signed {
                tick(at: CGPoint(x: x, y: statusY + 1.5), color: Ink.navy)
                draw(s.signedAt.map { "Signé électroniquement le \(parisDateTime.string(from: $0))" }
                        ?? "Signé électroniquement",
                     x: x + 11, y: statusY, attrs(f.bold(8), Ink.navy))
                let evidence = [s.smsVerified == true ? "Code SMS vérifié · \(s.smsPhone ?? "")"
                                                      : "Session authentifiée",
                                "Heure de Paris · art. 1367 du Code civil"]
                for (j, line) in evidence.enumerated() {
                    draw(line, x: x + 11, y: statusY + 12 + CGFloat(j) * 11, attrs(f.body(7.8), Ink.grey))
                }
            } else {
                ring(at: CGPoint(x: x, y: statusY + 1.5), color: Ink.faint)
                draw("En attente de signature", x: x + 11, y: statusY, attrs(f.body(8), Ink.grey))
            }
        }
        L.y += h
    }

    /// A check mark drawn rather than typed: the brand faces have no ✓, and a
    /// glyph borrowed from another font would differ from the server's copy.
    private static func tick(at origin: CGPoint, color: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: origin.x, y: origin.y + 3.4))
        path.addLine(to: CGPoint(x: origin.x + 2.4, y: origin.y + 5.8))
        path.addLine(to: CGPoint(x: origin.x + 6.6, y: origin.y + 0.6))
        path.lineWidth = 1.1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
    }

    /// An empty circle: a signature still to come.
    private static func ring(at origin: CGPoint, color: UIColor) {
        let path = UIBezierPath(ovalIn: CGRect(x: origin.x + 0.5, y: origin.y, width: 6, height: 6))
        path.lineWidth = 0.8
        color.setStroke(); path.stroke()
    }

    /// "18.09.2026 à 12:00", in Paris time, where the parties are.
    private static let parisDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "dd.MM.yyyy 'à' HH:mm"
        return f
    }()
    #endif
}
