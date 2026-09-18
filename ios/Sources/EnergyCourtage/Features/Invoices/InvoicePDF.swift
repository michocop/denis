import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Renders the attestation d'apport d'affaires as a PDF.
///
/// The PDF is a *rendering* of a document the database already fixed: what is
/// signed is `document_sha256`, the digest of `invoice_canonical_text()`. That
/// is deliberate — asking two devices to reproduce identical PDF bytes would
/// make the signature break the first time either side reflowed a line. So
/// this file is free to lay the page out for readability, and the legal
/// binding is unaffected by how it looks.
///
/// It is still written once and kept: art. 242 nonies A ann. II CGI requires
/// the issued invoice to be retained for ten years, so once a PDF exists for
/// an invoice the app downloads that one instead of re-rendering.
public enum InvoicePDF {

    /// A4 at 72dpi, the unit Core Graphics works in.
    static let pageSize = CGSize(width: 595.2, height: 841.8)
    static let margin: CGFloat = 56

    public static func render(_ doc: InvoiceDocument) -> Data {
        #if canImport(UIKit)
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize),
            format: metadata(for: doc)
        )
        return renderer.pdfData { context in
            var layout = Layout(context: context)
            layout.beginPage()
            draw(doc, into: &layout)
        }
        #else
        // The renderer is UIKit-only. On any other platform the app has no
        // screen to show it on either, so an empty document is honest.
        return Data()
        #endif
    }

    #if canImport(UIKit)
    private static func metadata(for doc: InvoiceDocument) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Facture \(doc.number)",
            kCGPDFContextAuthor as String: doc.apporteur.name,
            kCGPDFContextCreator as String: doc.issuer.company ?? doc.issuer.name,
            // Traceability back to what was signed, without which a saved file
            // cannot be matched to its invoice.
            kCGPDFContextSubject as String:
                "Attestation d'apport d'affaires — document \(doc.documentSha256 ?? "non scellé")"
        ]
        return format
    }

    /// A cursor down the page that starts a new one when it runs out of room,
    /// so a long prestation label or a wordy legal mention cannot silently
    /// spill off the bottom.
    private struct Layout {
        let context: UIGraphicsPDFRendererContext
        var y: CGFloat = margin

        var width: CGFloat { pageSize.width - margin * 2 }

        mutating func beginPage() {
            context.beginPage()
            y = margin
        }

        mutating func space(_ points: CGFloat) { y += points }

        mutating func text(_ string: String, font: UIFont,
                           alignment: NSTextAlignment = .natural,
                           color: UIColor = .black) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ]
            let bounds = (string as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil)

            if y + bounds.height > pageSize.height - margin { beginPage() }
            (string as NSString).draw(
                with: CGRect(x: margin, y: y, width: width, height: bounds.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil)
            y += ceil(bounds.height)
        }

        mutating func rule() {
            if y + 12 > pageSize.height - margin { beginPage() }
            y += 6
            let path = UIBezierPath()
            path.move(to: CGPoint(x: margin, y: y))
            path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
            UIColor(white: 0.8, alpha: 1).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            y += 6
        }
    }

    private static func draw(_ doc: InvoiceDocument, into layout: inout Layout) {
        let body = UIFont.systemFont(ofSize: 11)
        let bold = UIFont.boldSystemFont(ofSize: 11)
        let title = UIFont.boldSystemFont(ofSize: 15)
        let small = UIFont.systemFont(ofSize: 9)
        let grey = UIColor(white: 0.4, alpha: 1)

        layout.text(doc.issuer.company ?? doc.issuer.name, font: bold)
        layout.text(doc.issuer.name, font: body)
        if let city = doc.issuer.city { layout.text(city, font: body) }
        layout.space(18)

        layout.text(doc.apporteur.name, font: bold, alignment: .right)
        if let company = doc.apporteur.company {
            layout.text(company, font: body, alignment: .right)
        }
        if let siret = doc.apporteur.siret {
            layout.text("SIRET \(siret)", font: body, alignment: .right)
        }
        layout.space(28)

        layout.text("ATTESTATION D'APPORT D'AFFAIRES", font: title, alignment: .center)
        layout.space(6)
        layout.text("Facture n° \(doc.number)", font: bold, alignment: .center)
        layout.space(24)

        for (label, value) in [
            ("Je soussigné", doc.attestation.soussigne),
            ("Atteste avoir mis en relation", doc.attestation.misEnRelation ?? "—"),
            ("Avec", doc.attestation.avec),
            ("Pour la prestation suivante", doc.attestation.prestation),
            ("Intervenue le", doc.attestation.intervenueLe)
        ] {
            layout.text("\(label) : \(value)", font: body)
            layout.space(4)
        }

        layout.space(12)
        layout.rule()
        layout.text("Montant de la prestation : \(doc.amount.ttc) \(doc.amount.currency)",
                    font: bold)
        if doc.amount.vatRate > 0 {
            layout.text("dont TVA (\(doc.amount.vatRate as NSDecimalNumber) %) : "
                        + "\(doc.amount.vat) \(doc.amount.currency)", font: body)
            layout.text("Montant HT : \(doc.amount.ht) \(doc.amount.currency)", font: body)
        }
        layout.rule()
        layout.space(12)

        layout.text(doc.legalMentions, font: body)
        layout.space(6)
        layout.text("Modalité de règlement : \(doc.paymentMethod)", font: body)
        layout.text("Fait à \(doc.place), le \(doc.issuedOn)", font: body)

        if let notice = doc.taxNotice {
            layout.space(12)
            layout.text(notice, font: small, color: grey)
        }

        layout.space(28)
        layout.text("Signatures", font: bold)
        layout.space(6)
        for signature in doc.signatures {
            let state = signature.signed
                ? "signé\(signature.signedAt.map { " le " + Self.date.string(from: $0) } ?? "")"
                : "en attente"
            layout.text("\(signature.label) — \(signature.name) — \(state)", font: body)
            layout.space(2)
        }

        layout.space(24)
        layout.text(
            "Document scellé par empreinte SHA-256 : \(doc.documentSha256 ?? "non scellé")",
            font: small, color: grey)
    }

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()
    #endif
}
