import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The letter the client sends the supplier they are leaving, written from
/// the contract in the book. It is the client's letter, in the client's name
/// ("je" for a particulier, "nous" for a company), to be signed by them and
/// sent by recorded delivery; the company only prepares it.
public struct TerminationLetter: Equatable, Sendable {
    public var sender: [String]
    public var recipient: [String]
    public var placeAndDate: String
    public var postalMention: String
    public var subject: String
    public var references: [String]
    public var paragraphs: [String]
    public var signature: [String]

    /// What the letter needs and the contract lacks. The previous supplier is
    /// required (there is nobody to write to without it); the rest only
    /// weakens the letter, so it is said, not enforced.
    public static func missing(in c: SignedContract) -> [String] {
        var missing: [String] = []
        if c.previousSupplier?.nonBlank == nil { missing.append("l'ancien fournisseur") }
        if c.previousSupplierAddress?.nonBlank == nil { missing.append("l'adresse de l'ancien fournisseur") }
        if c.deliveryPoint?.nonBlank == nil {
            missing.append(c.energy == .electricite ? "le PDL/PRM" : "le PCE")
        }
        if c.previousReference?.nonBlank == nil { missing.append("le n° de client ou de contrat") }
        if c.postalAddress == nil { missing.append("l'adresse du client") }
        if c.isProfessional && c.signatoryName?.nonBlank == nil { missing.append("le signataire") }
        return missing
    }

    public static func canWrite(_ c: SignedContract) -> Bool {
        c.previousSupplier?.nonBlank != nil && !c.clientName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public init(contract c: SignedContract, on date: Date = .now) {
        let pro = c.isProfessional
        let name = c.clientName.trimmingCharacters(in: .whitespacesAndNewlines)

        var sender = [name]
        if pro, let signatory = c.signatoryName?.nonBlank {
            sender.append("Représentée par " + [signatory, c.signatoryTitle?.nonBlank]
                .compactMap { $0 }.joined(separator: ", "))
        }
        if let street = c.address?.nonBlank { sender.append(street) }
        let town = [c.postalCode?.nonBlank, c.city?.nonBlank].compactMap { $0 }.joined(separator: " ")
        if !town.isEmpty { sender.append(town) }
        if pro, let siret = c.siret?.nonBlank { sender.append("SIRET : \(siret)") }
        if let phone = c.phone?.nonBlank { sender.append("Tél. : \(phone)") }
        if let email = c.email?.nonBlank { sender.append(email) }
        self.sender = sender

        var recipient = [c.previousSupplier?.nonBlank ?? "Fournisseur"]
        let supplierLines = (c.previousSupplierAddress ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { String($0).nonBlank }
        recipient += supplierLines.isEmpty ? ["Service Clients – Résiliation"] : supplierLines
        self.recipient = recipient

        let when = "le \(ContractDay.long(date))"
        placeAndDate = c.city?.nonBlank.map { "À \($0), \(when)" } ?? "Le \(ContractDay.long(date))"
        postalMention = "Lettre recommandée avec accusé de réception"
        subject = "Objet : Résiliation du contrat de fourniture \(c.energy.supplyLabel)"

        var references: [String] = []
        if let reference = c.previousReference?.nonBlank {
            references.append("N° client / contrat : \(reference)")
        }
        if let point = c.deliveryPoint?.nonBlank {
            references.append("\(c.energy.deliveryPointLabel) : \(point)")
        }
        if let site = c.suppliedSiteAddress { references.append("Adresse du site : \(site)") }
        if pro, let siret = c.siret?.nonBlank { references.append("Titulaire : \(name) – SIRET \(siret)") }
        else { references.append("Titulaire : \(name)") }
        self.references = references

        let effect: String
        if let day = ContractDay.long(c.terminationOn) {
            effect = "Cette résiliation prendra effet le \(day)."
        } else if pro {
            effect = "Cette résiliation prendra effet à l'échéance de notre contrat, dans le respect du préavis contractuel."
        } else {
            effect = "Cette résiliation prendra effet dans les délais prévus par mon contrat."
        }

        let site = "pour le site référencé ci-dessus"
        if pro {
            paragraphs = [
                "Madame, Monsieur,",
                "Par la présente, nous vous informons de notre décision de résilier le contrat de fourniture \(c.energy.supplyLabel) souscrit auprès de vos services par \(name) \(site). \(effect)",
                "Nous vous remercions de bien vouloir procéder au relevé du compteur à cette date, de nous adresser la facture de clôture correspondante et, le cas échéant, de nous rembourser tout montant trop perçu. Nous vous remercions également de nous confirmer cette résiliation par écrit.",
                "Nous vous prions d'agréer, Madame, Monsieur, l'expression de nos salutations distinguées.",
            ]
            signature = [
                [c.signatoryName?.nonBlank, c.signatoryTitle?.nonBlank].compactMap { $0 }.joined(separator: ", "),
                "Pour \(name)",
            ].filter { !$0.isEmpty }
        } else {
            paragraphs = [
                "Madame, Monsieur,",
                "Par la présente, je vous informe de ma décision de résilier le contrat de fourniture \(c.energy.supplyLabel) souscrit auprès de vos services \(site). \(effect)",
                "Je vous remercie de bien vouloir procéder au relevé du compteur à cette date, de m'adresser la facture de clôture correspondante et, le cas échéant, de me rembourser tout montant trop perçu. Je vous remercie également de me confirmer cette résiliation par écrit.",
                "Je vous prie d'agréer, Madame, Monsieur, l'expression de mes salutations distinguées.",
            ]
            signature = [name]
        }
    }

    /// The file it is shared as.
    public static func filename(for c: SignedContract) -> String {
        let name = c.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return "Résiliation \(c.previousSupplier?.nonBlank ?? "fournisseur") - \(name).pdf"
            .replacingOccurrences(of: "/", with: "-")
    }
}

// MARK: - PDF

public enum TerminationLetterPDF {
    static let pageSize = CGSize(width: 595.28, height: 841.89)   // A4
    static let margin: CGFloat = 62

    public static func render(_ letter: TerminationLetter) -> Data {
        #if canImport(UIKit)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: letter.subject,
            kCGPDFContextAuthor as String: letter.sender.first ?? "",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        return renderer.pdfData { context in
            var writer = Writer(context: context)
            writer.page()
            writer.lines(letter.sender, font: .systemFont(ofSize: 10.5), firstBold: true)

            writer.y += 18
            writer.lines(letter.recipient, font: .systemFont(ofSize: 10.5), firstBold: true,
                         x: pageSize.width / 2 + 20)

            writer.y += 22
            writer.paragraph(letter.placeAndDate, font: .systemFont(ofSize: 10.5),
                             x: pageSize.width / 2 + 20)
            writer.y += 14
            writer.paragraph(letter.postalMention, font: .italicSystemFont(ofSize: 10))
            writer.y += 10
            writer.paragraph(letter.subject, font: .boldSystemFont(ofSize: 11))
            writer.y += 4
            writer.lines(letter.references, font: .systemFont(ofSize: 10))
            writer.y += 16
            for paragraph in letter.paragraphs {
                writer.paragraph(paragraph, font: .systemFont(ofSize: 11), leading: 4)
                writer.y += 10
            }
            writer.y += 14
            writer.keep(110)
            let x = pageSize.width / 2 + 20
            writer.lines(letter.signature, font: .systemFont(ofSize: 11), firstBold: true, x: x)
            writer.y += 6
            writer.paragraph("Signature :", font: .systemFont(ofSize: 9.5), color: .gray, x: x)
        }
        #else
        return Data()
        #endif
    }

    #if canImport(UIKit)
    private struct Writer {
        let context: UIGraphicsPDFRendererContext
        var y: CGFloat = 0
        var bottom: CGFloat { pageSize.height - margin }

        mutating func page() {
            context.beginPage()
            y = margin
        }

        mutating func keep(_ height: CGFloat) {
            if y + height > bottom { page() }
        }

        mutating func paragraph(_ text: String, font: UIFont, color: UIColor = .black,
                                x: CGFloat = margin, leading: CGFloat = 1.5) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = leading
            style.alignment = .natural
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]
            let width = pageSize.width - margin - x
            let string = NSAttributedString(string: text, attributes: attributes)
            let height = ceil(string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  context: nil).height)
            keep(height)
            string.draw(with: CGRect(x: x, y: y, width: width, height: height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += height
        }

        mutating func lines(_ lines: [String], font: UIFont, firstBold: Bool = false,
                            x: CGFloat = margin) {
            for (index, line) in lines.enumerated() {
                let face = index == 0 && firstBold
                    ? UIFont.boldSystemFont(ofSize: font.pointSize) : font
                paragraph(line, font: face, x: x, leading: 0)
                y += 1.5
            }
        }
    }
    #endif
}
