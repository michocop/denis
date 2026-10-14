import XCTest
import PDFKit
@testable import EnergyCourtage

/// Opens the PDF the app produces and reads it back.
///
/// The renderer had no test at all, so nothing would have noticed it dropping
/// a mandatory mention, printing a credit note as an invoice, or writing past
/// the bottom of the page. These check the file a tax inspector would get.
final class InvoicePDFTests: XCTestCase {

    private func sample() async throws -> InvoiceDocument {
        try await PreviewInvoiceRepository().document(invoiceID: UUID())
    }

    private func text(of document: InvoiceDocument) throws -> (String, Int) {
        let data = InvoicePDF.render(document)
        let pdf = try XCTUnwrap(PDFDocument(data: data), "the renderer produces a readable PDF")
        // PDF text extraction keeps the glyphs but not always the spacing, so
        // the checks below compare with whitespace collapsed.
        let raw = pdf.string ?? ""
        return (raw.split(whereSeparator: \.isWhitespace).joined(separator: " "), pdf.pageCount)
    }

    func testAnInvoiceCarriesEveryMandatoryMention() async throws {
        let (text, pages) = try text(of: try await sample())

        XCTAssertEqual(pages, 1)
        for expected in [
            "FACTURE", "N° FA-2026-0001",
            "DATE D'ÉMISSION 17.09.2026",
            "ÉCHÉANCE 17.10.2026",
            // the supplier is the apporteur, with an address
            "FOURNISSEUR", "Johann Lefeuvre", "12 rue des Lilas", "59000 Lille",
            "SIRET 12345678900011",
            // the customer is the company, by its legal identity
            "CLIENT", "TRINITY ENERGIE", "SAS au capital de 1 000 €",
            "945 rue du Général de Gaulle", "59310 Aix-en-Pévèle", "SIREN 102470705 · RCS Lille Métropole",
            "Autofacturation",
            "Total HT", "Total TTC", "300,00 €",
            "Article 293B",
            "au plus tard le 17.10.2026",
            "40 €", "L441-10",
            "Je soussigné(e) Johann Lefeuvre atteste",
            "SIGNATURES ÉLECTRONIQUES", "L'APPORTEUR", "L'ENTREPRISE",
            "Page 1 / 1",
            "Empreinte SHA-256 du document signé : 6b3788b6 c0f4de8a da808ece 4ce874fe "
                + "03115720 fbe79519 337ce86e a382d5d8"
        ] {
            XCTAssertTrue(text.contains(expected), "the PDF says “\(expected)”")
        }
    }

    func testACreditNoteIsTitledAsOneAndNamesWhatItCancels() async throws {
        var note = try await sample()
        note.number = "FA-2026-0007"
        note.kind = "credit_note"
        note.correctsNumber = "FA-2026-0001"
        note.amount = .init(ht: "-300.00", vatRate: 0, vat: "0.00", ttc: "-300.00",
                            currency: "EUR")

        let (text, _) = try text(of: note)
        XCTAssertTrue(text.contains("AVOIR") && text.contains("N° FA-2026-0007"), "a credit note says it is one")
        XCTAssertFalse(text.contains("FACTURE"), "and not that it is an invoice")
        XCTAssertTrue(text.contains("Total TTC à déduire"))
        XCTAssertTrue(text.contains("Avoir sur la facture n° FA-2026-0001"),
                      "naming the invoice it cancels")
        XCTAssertTrue(text.contains("-300,00 €"))
    }

    func testLargeAmountsAreWrittenTheFrenchWay() {
        XCTAssertEqual(InvoicePDF.money("12500.00", "EUR"), "12 500,00\u{00A0}€")
        XCTAssertEqual(InvoicePDF.money("-1234567.50", "EUR"), "-1 234 567,50\u{00A0}€")
        XCTAssertEqual(InvoicePDF.money("300.00", "EUR"), "300,00\u{00A0}€")
    }

    /// A wordy label used to be the thing that ran off the bottom of the page.
    func testALongDocumentFlowsOntoAnotherPageWithItsFooter() async throws {
        var long = try await sample()
        long.attestation.prestation = String(repeating: "Apport d'affaires détaillé. ", count: 120)

        let (text, pages) = try text(of: long)
        XCTAssertGreaterThan(pages, 1, "the text continues on a new page")
        XCTAssertTrue(text.contains("Page 2 / \(pages)"), "which is numbered, out of the total")
        XCTAssertTrue(text.contains("FACTURE N° FA-2026-0001 — SUITE"), "and says what it continues")
        XCTAssertTrue(text.contains("L'ENTREPRISE"),
                      "and nothing after the long part is lost")
    }

    /// Invoices issued before the company's legal identity was recorded still
    /// render, naming the company as they did then.
    func testAnInvoiceFromBeforeTheMentionsStillRenders() async throws {
        var old = try await sample()
        old.customer = nil
        old.dueOn = nil
        old.selfBillingMention = nil
        old.latePaymentMention = nil

        let (text, _) = try text(of: old)
        XCTAssertTrue(text.contains("CLIENT Trinity Énergie"))
        XCTAssertTrue(text.contains("Total TTC"))
    }

    /// Writes the sample to PDF_OUT, when set, to look at the page itself.
    func testWritesTheSampleForInspection() async throws {
        guard let path = ProcessInfo.processInfo.environment["PDF_OUT"] else { return }
        var doc = try await sample()
        doc.signatures[0].smsVerified = true
        doc.signatures[0].smsPhone = "+33 6 •• •• •• 78"
        try InvoicePDF.render(doc).write(to: URL(fileURLWithPath: path))
    }
}
