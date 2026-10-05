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

    private enum Ink {
        static let navy = color(0x0A1F4A)
        static let brand = color(0x1F5FFF)
        static let mark = color(0x3C8BFF)
        static let ice = color(0xC3D7FF)
        static let text = color(0x0E1630)
        static let grey = color(0x5B6478)
        static let faint = color(0x8A93A6)
        static let tint = color(0xF3F6FC)
        static let tintBlue = color(0xEAF1FF)
        static let border = color(0xDDE4F0)
        static let green = color(0x0E9F6E)
        static let greenTint = color(0xE3F6EE)
        static let amber = color(0xB7791F)
        static let amberTint = color(0xFBF1DE)
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

    private static func box(_ rect: CGRect, radius: CGFloat, fill: UIColor?, stroke: UIColor? = nil) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: min(radius, rect.height / 2))
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.lineWidth = 0.75; path.stroke() }
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
            let a = attrs(fonts.bold(7.5), Ink.brand, kern: 0.45)
            draw(label, x: margin, y: y, a)
            let w = width(label, a)
            let rule = UIBezierPath()
            rule.move(to: CGPoint(x: margin + w + 10, y: y + 5))
            rule.addLine(to: CGPoint(x: pageSize.width - margin, y: y + 5))
            rule.lineWidth = 0.5
            Ink.border.setStroke(); rule.stroke()
            y += 16
        }

        func footer() {
            let line = pageSize.height - footerTop
            let rule = UIBezierPath()
            rule.move(to: CGPoint(x: margin, y: line))
            rule.addLine(to: CGPoint(x: pageSize.width - margin, y: line))
            rule.lineWidth = 0.5
            Ink.border.setStroke(); rule.stroke()
            logo(at: CGPoint(x: margin, y: line + 8), size: 9, line: Ink.navy)
            let label = "\(doc.isCreditNote ? "Avoir" : "Facture") \(doc.number) · Trinity Énergie"
            draw(label, x: margin + 14, y: line + 7, attrs(fonts.bold(7.2), Ink.grey))
            drawRight("Page \(page) / \(totalPages)", right: pageSize.width - margin, y: line + 7,
                      attrs(fonts.bold(7.2), Ink.grey))
            draw("Empreinte SHA-256 du document signé : \(grouped(doc.documentSha256))",
                 x: margin, y: line + 22, attrs(fonts.body(6.4), Ink.faint))
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
            if let mention = doc.selfBillingMention { callout(&L, mention) }
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

    private static func header(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let band: CGFloat = 100
        Ink.navy.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: pageSize.width, height: band))
        let sweep = UIBezierPath()
        sweep.move(to: CGPoint(x: pageSize.width * 0.55, y: 0))
        sweep.addLine(to: CGPoint(x: pageSize.width, y: 0))
        sweep.addLine(to: CGPoint(x: pageSize.width, y: band))
        sweep.addLine(to: CGPoint(x: pageSize.width * 0.72, y: band))
        sweep.close()
        Ink.brand.withAlphaComponent(0.16).setFill(); sweep.fill()
        Ink.brand.setFill()
        UIRectFill(CGRect(x: 0, y: band, width: pageSize.width, height: 3))

        logo(at: CGPoint(x: margin, y: 26), size: 26, line: .white)
        draw("TRINITY ÉNERGIE", x: margin + 36, y: 33, attrs(f.display(10.5), .white, kern: 2.4))
        draw(doc.isCreditNote ? "Avoir en autofacturation"
                              : "Autofacturation · établie au nom et pour le compte de l'apporteur",
             x: margin, y: 63, attrs(f.body(8), Ink.ice))

        drawRight(title(for: doc), right: pageSize.width - margin, y: 26, attrs(f.display(22), .white, kern: 1.5))
        drawRight("N° \(doc.number)", right: pageSize.width - margin, y: 58, attrs(f.bold(11), Ink.ice))
        if doc.isCreditNote, let original = doc.correctsNumber {
            drawRight("Avoir sur la facture n° \(original)", right: pageSize.width - margin, y: 76,
                      attrs(f.body(8), Ink.ice))
        }
        L.y = band + 3 + 18
    }

    /// Three tiles: when it was issued, when it is due, how much.
    private static func keyFacts(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let gap: CGFloat = 10, h: CGFloat = 48, w = (content - gap * 2) / 3
        let tiles: [(String, String, Bool)] = [
            ("DATE D'ÉMISSION", doc.issuedOn, false),
            ("ÉCHÉANCE", doc.dueOn ?? "À réception", false),
            (doc.isCreditNote ? "MONTANT À DÉDUIRE" : "MONTANT TTC",
             money(doc.amount.ttc, doc.amount.currency), true)
        ]
        for (i, tile) in tiles.enumerated() {
            let x = margin + CGFloat(i) * (w + gap)
            box(CGRect(x: x, y: L.y, width: w, height: h), radius: 10, fill: tile.2 ? Ink.brand : Ink.tint)
            draw(tile.0, x: x + 14, y: L.y + 10, attrs(f.bold(6.8), tile.2 ? Ink.ice : Ink.faint, kern: 0.4))
            draw(tile.1, x: x + 14, y: L.y + 22,
                 attrs(tile.2 ? f.display(15) : f.bold(12.5), tile.2 ? .white : Ink.text))
        }
        L.y += h + 14
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

    /// The two parties, as cards side by side.
    private static func parties(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let gap: CGFloat = 12, w = (content - gap) / 2, pad: CGFloat = 14, leading: CGFloat = 12.4
        let inner = w - pad * 2
        let nameAttrs = attrs(f.bold(10.5), Ink.text)
        let lineAttrs = attrs(f.body(8.6), Ink.grey)
        let customer = customerLines(doc)
        let cards: [(String, String, [String])] = [
            ("FOURNISSEUR · APPORTEUR", doc.apporteur.name, supplierLines(doc)),
            ("CLIENT", customer.0, customer.1)
        ]
        func measure(_ c: (String, String, [String])) -> CGFloat {
            pad + 14 + CGFloat(wrap(c.1, nameAttrs, inner).count) * 14
                + CGFloat(c.2.reduce(0) { $0 + wrap($1, lineAttrs, inner).count }) * leading + pad
        }
        let h = cards.map(measure).max() ?? 0
        L.keep(h)
        for (i, card) in cards.enumerated() {
            let x = margin + CGFloat(i) * (w + gap)
            box(CGRect(x: x, y: L.y, width: w, height: h), radius: 10, fill: .white, stroke: Ink.border)
            draw(card.0, x: x + pad, y: L.y + pad - 1, attrs(f.bold(6.8), Ink.brand, kern: 0.4))
            var y = L.y + pad + 14
            for line in wrap(card.1, nameAttrs, inner) { draw(line, x: x + pad, y: y, nameAttrs); y += 14 }
            for text in card.2 {
                for line in wrap(text, lineAttrs, inner) { draw(line, x: x + pad, y: y, lineAttrs); y += leading }
            }
        }
        L.y += h + 12
    }

    /// A line of emphasis with a brand bar on its left.
    private static func callout(_ L: inout Layout, _ text: String) {
        let a = attrs(L.fonts.bold(8.4), Ink.navy)
        let leading: CGFloat = 11.8, pad: CGFloat = 10
        let lines = wrap(text, a, content - 28)
        let h = CGFloat(lines.count) * leading + pad * 2 - 2
        L.keep(h)
        box(CGRect(x: margin, y: L.y, width: content, height: h), radius: 6, fill: Ink.tintBlue)
        Ink.brand.setFill()
        UIRectFill(CGRect(x: margin, y: L.y, width: 3, height: h))
        var y = L.y + pad - 1
        for line in lines { draw(line, x: margin + 16, y: y, a); y += leading }
        L.y += h + 12
    }

    /// Désignation · Qté · Prix unitaire HT · Montant HT.
    private static func lineItems(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let qtyX = margin + content - 210, unitX = margin + content - 150, totalX = margin + content - 12
        let designationWidth = qtyX - margin - 24
        let headAttrs = attrs(f.bold(7), .white, kern: 0.4)

        func headerRow(_ L: inout Layout) {
            L.keep(60)
            box(CGRect(x: margin, y: L.y, width: content, height: 24), radius: 6, fill: Ink.navy)
            draw("DÉSIGNATION", x: margin + 12, y: L.y + 8, headAttrs)
            draw("QTÉ", x: qtyX, y: L.y + 8, headAttrs)
            draw("PRIX UNIT. HT", x: unitX, y: L.y + 8, headAttrs)
            drawRight("MONTANT HT", right: totalX, y: L.y + 8, headAttrs)
            L.y += 32
        }
        headerRow(&L)

        let amount = money(doc.amount.ht, doc.amount.currency)
        let rowAttrs = attrs(f.bold(9.5), Ink.text)
        let plain = attrs(f.body(9.5), Ink.text)
        for (i, line) in wrap(doc.attestation.prestation, rowAttrs, designationWidth).enumerated() {
            if L.y + 13.5 > L.bottom { L.newPage(); headerRow(&L) }
            draw(line, x: margin + 12, y: L.y, rowAttrs)
            if i == 0 {
                draw("1", x: qtyX + 4, y: L.y, plain)
                draw(amount, x: unitX, y: L.y, plain)
                drawRight(amount, right: totalX, y: L.y, rowAttrs)
            }
            L.y += 13.5
        }
        L.text("Mise en relation avec \(doc.attestation.avec), intervenue le \(doc.attestation.intervenueLe).",
               font: f.body(8), color: Ink.grey, x: margin + 12, width: designationWidth)
        L.y += 8
        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: margin, y: L.y)); rule.addLine(to: CGPoint(x: margin + content, y: L.y))
        rule.lineWidth = 0.75
        Ink.border.setStroke(); rule.stroke()
        L.y += 14
    }

    /// Totals, flush right, ending on a navy band. Payment terms on the left.
    private static func totals(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts, cur = doc.amount.currency
        let w: CGFloat = 228, x = margin + content - w
        let rows = [("Total HT", money(doc.amount.ht, cur)),
                    ("TVA (\((doc.amount.vatRate as NSDecimalNumber).stringValue.replacingOccurrences(of: ".", with: ",")) %)",
                     money(doc.amount.vat, cur))]
        let termAttrs = attrs(f.body(8), Ink.grey)
        let leftWidth = content - w - 24
        let terms = ["Règlement : \(doc.paymentMethod)" + (doc.dueOn.map { ", au plus tard le \($0)" } ?? "") + ".",
                     "Fait à \(doc.place), le \(doc.issuedOn)."].flatMap { wrap($0, termAttrs, leftWidth) }
        L.keep(max(CGFloat(rows.count) * 20 + 40, CGFloat(terms.count) * 11.5 + 18))
        let top = L.y

        draw("CONDITIONS", x: margin, y: top, attrs(f.bold(6.8), Ink.brand, kern: 0.4))
        var ty = top + 14
        for line in terms { draw(line, x: margin, y: ty, termAttrs); ty += 11.5 }

        var y = top
        for (label, value) in rows {
            draw(label, x: x + 12, y: y + 4, attrs(f.body(9.5), Ink.grey))
            drawRight(value, right: x + w - 12, y: y + 4, attrs(f.body(9.5), Ink.text))
            y += 20
        }
        y += 6
        box(CGRect(x: x, y: y, width: w, height: 30), radius: 8, fill: Ink.navy)
        draw(doc.isCreditNote ? "Total TTC à déduire" : "Total TTC", x: x + 12, y: y + 8,
             attrs(f.bold(10), .white))
        drawRight(money(doc.amount.ttc, cur), right: x + w - 12, y: y + 6, attrs(f.display(13), .white))
        L.y = max(y + 30, ty) + 10
    }

    private static func mentions(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        L.heading("MENTIONS LÉGALES")
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

    /// One panel per party: who signed, when, and what proves it.
    private static func signatures(_ L: inout Layout) {
        let doc = L.doc, f = L.fonts
        let gap: CGFloat = 12, w = (content - gap) / 2, pad: CGFloat = 14, h: CGFloat = 96
        L.keep(h + 24)   // the heading stays with its panels
        L.heading("SIGNATURES ÉLECTRONIQUES")
        for (i, s) in doc.signatures.prefix(2).enumerated() {
            let x = margin + CGFloat(i) * (w + gap)
            box(CGRect(x: x, y: L.y, width: w, height: h), radius: 10, fill: s.signed ? .white : Ink.tint,
                stroke: Ink.border)
            draw(s.role == "apporteur" ? "L'APPORTEUR" : "L'ENTREPRISE", x: x + pad, y: L.y + pad - 1,
                 attrs(f.bold(6.8), Ink.faint, kern: 0.4))

            let pill = s.signed ? "Signé" : "En attente"
            let pillAttrs = attrs(f.bold(7.5), s.signed ? Ink.green : Ink.amber)
            let pw = width(pill, pillAttrs) + 22
            let pillRect = CGRect(x: x + w - pad - pw, y: L.y + pad - 3, width: pw, height: 16)
            box(pillRect, radius: 8, fill: s.signed ? Ink.greenTint : Ink.amberTint)
            (s.signed ? Ink.green : Ink.amber).setFill()
            UIBezierPath(ovalIn: CGRect(x: pillRect.minX + 6.6, y: pillRect.midY - 2.4, width: 4.8, height: 4.8)).fill()
            draw(pill, x: pillRect.minX + 15, y: pillRect.minY + 3, pillAttrs)

            draw(s.name, x: x + pad, y: L.y + pad + 16, attrs(f.bold(11), Ink.text))
            let evidence: [String] = s.signed
                ? [s.signedAt.map { "Le \(parisDateTime.string(from: $0)) (heure de Paris)" }
                    ?? "Signé électroniquement",
                   s.smsVerified == true ? "Code SMS vérifié · \(s.smsPhone ?? "")" : "Session authentifiée",
                   "Signature électronique · art. 1367 C. civ."]
                : ["Signature attendue"]
            for (j, line) in evidence.enumerated() {
                let sms = j == 1 && s.smsVerified == true
                draw(line, x: x + pad, y: L.y + pad + 38 + CGFloat(j) * 12.5,
                     attrs(f.body(8), sms ? Ink.green : Ink.grey))
            }
        }
        L.y += h + 10
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
