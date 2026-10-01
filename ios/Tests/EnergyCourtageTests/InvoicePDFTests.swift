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
            "FACTURE N° FA-2026-0001",
            "Date d'émission : 17.09.2026",
            "Échéance : 17.10.2026",
            // the supplier is the apporteur, with an address
            "FOURNISSEUR", "Johann Lefeuvre", "12 rue des Lilas", "59000 Lille",
            "SIRET 12345678900011",
            // the customer is the company, by its legal identity
            "CLIENT", "Trinity Énergie", "SAS au capital de 10 000 €",
            "1 rue de la Gare", "59310 Aix-en-Pévèle", "SIREN 000000000 — RCS Lille",
            "Autofacturation",
            "Total HT", "Total TTC", "300,00 €",
            "Article 293B",
            "au plus tard le 17.10.2026",
            "40 €", "L441-10",
            "Signature de l'apporteur", "Signature de l'entreprise",
            "empreinte SHA-256 " + String(repeating: "a", count: 64)
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
        XCTAssertTrue(text.contains("AVOIR N° FA-2026-0007"), "a credit note says it is one")
        XCTAssertFalse(text.contains("FACTURE N°"), "and not that it is an invoice")
        XCTAssertTrue(text.contains("Avoir sur la facture n° FA-2026-0001"),
                      "naming the invoice it cancels")
        XCTAssertTrue(text.contains("-300,00 €"))
    }

    /// A wordy label used to be the thing that ran off the bottom of the page.
    func testALongDocumentFlowsOntoAnotherPageWithItsFooter() async throws {
        var long = try await sample()
        long.attestation.prestation = String(repeating: "Apport d'affaires détaillé. ", count: 120)

        let (text, pages) = try text(of: long)
        XCTAssertGreaterThan(pages, 1, "the text continues on a new page")
        XCTAssertTrue(text.contains("page 2"), "which is numbered")
        XCTAssertTrue(text.contains("Signature de l'entreprise"),
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
}
