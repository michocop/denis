import Foundation
#if canImport(UIKit)
import UIKit
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
/// late-payment terms. The previous page was an attestation naming the admin
/// who issued it, and a credit note came out looking like an invoice.
///
/// It is still written once and kept: art. 242 nonies A ann. II CGI requires
/// the issued invoice to be retained for ten years, so once a PDF exists for
/// an invoice the app downloads that one instead of re-rendering.
public enum InvoicePDF {

    /// A4 at 72dpi, the unit Core Graphics works in.
    static let pageSize = CGSize(width: 595.2, height: 841.8)
    static let margin: CGFloat = 48
    /// Kept clear at the bottom of every page for the footer.
    static let footerHeight: CGFloat = 28

    public static func render(_ doc: InvoiceDocument) -> Data {
        #if canImport(UIKit)
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize),
            format: metadata(for: doc)
        )
        return renderer.pdfData { context in
            var layout = Layout(context: context, footer: footer(for: doc))
            layout.beginPage()
            draw(doc, into: &layout)
        }
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

    #if canImport(UIKit)
    private static func metadata(for doc: InvoiceDocument) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        let customer = doc.customer?.legalName ?? doc.issuer.company ?? doc.issuer.name
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(title(for: doc).capitalized) \(doc.number)",
            kCGPDFContextAuthor as String: doc.apporteur.name,
            kCGPDFContextCreator as String: customer,
            // Traceability back to what was signed, without which a saved file
            // cannot be matched to its invoice.
            kCGPDFContextSubject as String:
                "Autofacturation — document \(doc.documentSha256 ?? "non scellé")"
        ]
        return format
    }

    private static func footer(for doc: InvoiceDocument) -> String {
        "\(title(for: doc).capitalized) \(doc.number) — empreinte SHA-256 "
            + (doc.documentSha256 ?? "non scellé")
    }

    // MARK: - Layout

    /// A cursor down the page that starts a new one when it runs out of room,
    /// so a long prestation label or a wordy legal mention cannot silently
    /// spill off the bottom. Every page gets the footer and its number.
    private struct Layout {
        let context: UIGraphicsPDFRendererContext
        let footer: String
        var y: CGFloat = margin
        var page = 0

        var width: CGFloat { pageSize.width - margin * 2 }
        var bottom: CGFloat { pageSize.height - margin - footerHeight }

        mutating func beginPage() {
            context.beginPage()
            page += 1
            y = margin
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 7.5),
                .foregroundColor: UIColor(white: 0.45, alpha: 1)
            ]
            let text = "\(footer) — page \(page)" as NSString
            text.draw(with: CGRect(x: margin, y: pageSize.height - margin - 10,
                                   width: width, height: 20),
                      options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        }

        mutating func space(_ points: CGFloat) { y += points }

        /// Starts a new page unless `points` still fit, so a block that belongs
        /// together -- the totals, the signatures -- is not cut in half.
        mutating func keep(_ points: CGFloat) {
            if y + points > bottom { beginPage() }
        }

        static func attributes(_ font: UIFont, _ color: UIColor,
                               _ alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        }

        static func height(of string: String, width: CGFloat,
                           attributes: [NSAttributedString.Key: Any]) -> CGFloat {
            ceil((string as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil).height)
        }

        mutating func text(_ string: String, font: UIFont,
                           alignment: NSTextAlignment = .natural,
                           color: UIColor = .black) {
            let attributes = Self.attributes(font, color, alignment)
            let height = Self.height(of: string, width: width, attributes: attributes)
            keep(height)
            (string as NSString).draw(
                with: CGRect(x: margin, y: y, width: width, height: height),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil)
            y += height
        }

        /// Two blocks side by side -- the supplier and the customer -- advancing
        /// by the taller of the two.
        mutating func columns(_ left: [(String, UIFont)], _ right: [(String, UIFont)]) {
            let gutter: CGFloat = 24
            let columnWidth = (width - gutter) / 2
            func measure(_ lines: [(String, UIFont)]) -> CGFloat {
                lines.reduce(0) {
                    $0 + Self.height(of: $1.0, width: columnWidth,
                                     attributes: Self.attributes($1.1, .black, .natural)) + 2
                }
            }
            keep(max(measure(left), measure(right)))
            let top = y
            var bottomOfColumns = top
            for (lines, x) in [(left, margin), (right, margin + columnWidth + gutter)] {
                var cursor = top
                for (string, font) in lines {
                    let attributes = Self.attributes(font, .black, .natural)
                    let height = Self.height(of: string, width: columnWidth, attributes: attributes)
                    (string as NSString).draw(
                        with: CGRect(x: x, y: cursor, width: columnWidth, height: height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: attributes, context: nil)
                    cursor += height + 2
                }
                bottomOfColumns = max(bottomOfColumns, cursor)
            }
            y = bottomOfColumns
        }

        /// A label on the left and an amount flush right, on one line.
        mutating func row(_ label: String, _ value: String, font: UIFont) {
            let left = Self.attributes(font, .black, .natural)
            let right = Self.attributes(font, .black, .right)
            let height = Self.height(of: label, width: width * 0.7, attributes: left)
            keep(height)
            (label as NSString).draw(with: CGRect(x: margin, y: y, width: width * 0.7, height: height),
                                     options: [.usesLineFragmentOrigin], attributes: left, context: nil)
            (value as NSString).draw(with: CGRect(x: margin, y: y, width: width, height: height),
                                     options: [.usesLineFragmentOrigin], attributes: right, context: nil)
            y += height + 3
        }

        mutating func rule() {
            keep(12)
            y += 5
            let path = UIBezierPath()
            path.move(to: CGPoint(x: margin, y: y))
            path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
            UIColor(white: 0.8, alpha: 1).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            y += 6
        }
    }

    // MARK: - The page

    private static func draw(_ doc: InvoiceDocument, into layout: inout Layout) {
        let body = UIFont.systemFont(ofSize: 10)
        let bold = UIFont.boldSystemFont(ofSize: 10)
        let heading = UIFont.boldSystemFont(ofSize: 8.5)
        let title = UIFont.boldSystemFont(ofSize: 18)
        let small = UIFont.systemFont(ofSize: 8.5)
        let grey = UIColor(white: 0.4, alpha: 1)
        let money = { (amount: String) in Self.money(amount, doc.amount.currency) }

        // Title, number, dates
        layout.text("\(Self.title(for: doc)) N° \(doc.number)", font: title)
        layout.space(4)
        var dates = "Date d'émission : \(doc.issuedOn)"
        if let due = doc.dueOn { dates += "     Échéance : \(due)" }
        layout.text(dates, font: body)
        if doc.isCreditNote, let original = doc.correctsNumber {
            layout.text("Avoir sur la facture n° \(original)", font: bold)
        }
        layout.space(14)

        // The two parties. The supplier is the apporteur: the company only
        // draws the invoice up in their name.
        layout.columns(supplierLines(doc, heading: heading, bold: bold, body: body),
                       customerLines(doc, heading: heading, bold: bold, body: body))
        layout.space(10)

        if let selfBilling = doc.selfBillingMention {
            layout.text(selfBilling, font: bold)
            layout.space(10)
        }

        // What is invoiced
        layout.rule()
        layout.row("DÉSIGNATION", "MONTANT HT", font: heading)
        layout.rule()
        layout.row(doc.attestation.prestation,
                   money(doc.amount.ht), font: body)
        layout.text("Mise en relation avec \(doc.attestation.avec), "
                    + "intervenue le \(doc.attestation.intervenueLe).",
                    font: small, color: grey)
        layout.rule()

        // Totals, kept together
        layout.keep(60)
        layout.row("Total HT", money(doc.amount.ht), font: body)
        layout.row("TVA (\(doc.amount.vatRate as NSDecimalNumber) %)",
                   money(doc.amount.vat), font: body)
        layout.row(doc.isCreditNote ? "Total TTC à déduire" : "Total TTC",
                   money(doc.amount.ttc), font: bold)
        layout.rule()
        layout.space(8)

        // Mentions
        layout.text(doc.legalMentions, font: small)
        layout.text("Règlement : \(doc.paymentMethod)"
                    + (doc.dueOn.map { ", au plus tard le \($0)" } ?? "") + ".",
                    font: small)
        if let late = doc.latePaymentMention {
            layout.text(late, font: small)
        }
        layout.text("Fait à \(doc.place), le \(doc.issuedOn).", font: small)
        layout.space(12)

        // The attestation the source app carried, kept for the apporteur
        if !doc.isCreditNote {
            layout.text("Je soussigné(e) \(doc.attestation.soussigne) atteste avoir mis en relation "
                        + "\(doc.attestation.misEnRelation ?? "la société") avec "
                        + "\(doc.attestation.avec) pour la prestation ci-dessus.",
                        font: small)
            layout.space(12)
        }

        if let notice = doc.taxNotice {
            layout.text(notice, font: small, color: grey)
            layout.space(12)
        }

        // Signatures, kept together
        layout.keep(70)
        layout.text("SIGNATURES", font: heading)
        layout.space(4)
        for signature in doc.signatures {
            let state = signature.signed
                ? "signé électroniquement\(signature.signedAt.map { " le " + Self.date.string(from: $0) } ?? "")"
                : "en attente"
            layout.text("\(signature.label) — \(signature.name) — \(state)", font: body)
            layout.space(2)
        }
    }

    private static func supplierLines(_ doc: InvoiceDocument, heading: UIFont,
                                      bold: UIFont, body: UIFont) -> [(String, UIFont)] {
        let party = doc.apporteur
        var lines: [(String, UIFont)] = [("FOURNISSEUR", heading), (party.name, bold)]
        if let company = party.company, !company.isEmpty { lines.append((company, body)) }
        if let form = party.legalForm, !form.isEmpty { lines.append((form, body)) }
        if let address = party.address, !address.isEmpty { lines.append((address, body)) }
        let town = [party.postalCode, party.city].compactMap { $0 }.joined(separator: " ")
        if !town.isEmpty { lines.append((town, body)) }
        if let siret = party.siret, !siret.isEmpty { lines.append(("SIRET \(siret)", body)) }
        if let vat = party.vatNumber, !vat.isEmpty { lines.append(("TVA \(vat)", body)) }
        return lines
    }

    private static func customerLines(_ doc: InvoiceDocument, heading: UIFont,
                                      bold: UIFont, body: UIFont) -> [(String, UIFont)] {
        guard let customer = doc.customer else {
            // Issued before the company's identity was recorded.
            var lines: [(String, UIFont)] = [("CLIENT", heading),
                                             (doc.issuer.company ?? doc.issuer.name, bold)]
            if let city = doc.issuer.city { lines.append((city, body)) }
            return lines
        }
        var lines: [(String, UIFont)] = [("CLIENT", heading), (customer.legalName, bold)]
        let form = [customer.legalForm, customer.shareCapital.map { "au capital de \($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        if !form.isEmpty { lines.append((form, body)) }
        lines.append((customer.address, body))
        lines.append(("\(customer.postalCode) \(customer.city)", body))
        lines.append(("SIREN \(customer.siren)"
                      + (customer.rcsCity.map { " — RCS \($0)" } ?? ""), body))
        if let vat = customer.vatNumber, !vat.isEmpty { lines.append(("TVA \(vat)", body)) }
        return lines
    }

    /// "300.00" from the server, "300,00 €" on the page: the database sends
    /// amounts in a fixed machine format so nothing is lost to a locale, and
    /// the French way of writing them is applied only when drawing.
    static func money(_ amount: String, _ currency: String) -> String {
        let symbol = currency == "EUR" ? "€" : currency
        return amount.replacingOccurrences(of: ".", with: ",") + "\u{00A0}" + symbol
    }

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()
    #endif
}
