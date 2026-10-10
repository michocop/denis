import XCTest
import PDFKit
@testable import EnergyCourtage

final class SmsTests: XCTestCase {

    func testAMobileIsUnderstoodHoweverItIsTyped() {
        XCTAssertEqual(MobileNumber.e164("06 12 34 56 78"), "+33612345678")
        XCTAssertEqual(MobileNumber.e164("07.12.34.56.78"), "+33712345678")
        XCTAssertEqual(MobileNumber.e164("+33 6 12 34 56 78"), "+33612345678")
        XCTAssertEqual(MobileNumber.e164("0033612345678"), "+33612345678")
        XCTAssertEqual(MobileNumber.e164("+44 7700 900123"), "+447700900123")
        XCTAssertNil(MobileNumber.e164("01 23 45 67 89"), "a landline receives no SMS")
        XCTAssertNil(MobileNumber.e164("06 12 34"))
        XCTAssertNil(MobileNumber.e164("+33 1 23 45 67 89"))
        XCTAssertNil(MobileNumber.e164("bonjour"))
    }

    func testOnlySixDigitsOfACodeAreKept() {
        XCTAssertEqual(MobileNumber.code(" 123 456 "), "123456")
        XCTAssertEqual(MobileNumber.code("Code : 1234567"), "123456")
        XCTAssertEqual(MobileNumber.code("١٢٣"), "", "only ASCII digits, as the server compares them")
    }

    /// Until the company sets SMS up, "Signer" signs, as it always did.
    @MainActor
    func testWithoutSmsTheApporteurSignsAtOnce() async throws {
        let invoices = RecordingInvoices()
        let model = InvoiceViewModel(invoiceID: UUID(), repository: invoices,
                                     sms: PreviewSmsRepository(required: false))
        await model.load()
        await model.startSigning(asCompany: false)
        XCTAssertNil(model.signingStep)
        let signed = await invoices.signatures
        XCTAssertEqual(signed, 1)
    }

    /// With SMS set up and no proven number, the number comes first, and the
    /// one code sent to it both proves it and confirms the signature.
    @MainActor
    func testAFirstSignatureTakesOneSMS() async throws {
        let invoices = RecordingInvoices()
        let sms = PreviewSmsRepository(required: true)
        let model = InvoiceViewModel(invoiceID: UUID(), repository: invoices, sms: sms)
        await model.load()

        await model.startSigning(asCompany: false)
        XCTAssertEqual(model.signingStep, .enterPhone)

        let challenge = try await model.requestSigningCode(phone: "06 12 34 56 78", resend: false)
        XCTAssertEqual(challenge.maskedPhone, "+33 6 •• •• •• 78")
        var signed = await invoices.signatures
        XCTAssertEqual(signed, 0, "nothing is signed before the code")

        let wrong = try await model.confirmSigningCode("000000")
        XCTAssertFalse(wrong.ok)
        XCTAssertEqual(wrong.attemptsLeft, 4)

        let right = try await model.confirmSigningCode(PreviewSmsRepository.demoCode)
        XCTAssertTrue(right.ok)
        await model.codeConfirmed()
        XCTAssertNil(model.signingStep)
        signed = await invoices.signatures
        XCTAssertEqual(signed, 1)
        let sent = await sms.sent
        XCTAssertEqual(sent, 1, "one SMS proved the number and confirmed the signature")
        let status = try await sms.status()
        XCTAssertTrue(status.phoneVerified)
    }

    /// Within ten minutes of a confirmed code, the next signature needs no SMS;
    /// and reopening the code screen reuses the code already sent.
    @MainActor
    func testSignaturesInTheSameTenMinutesShareOneSMS() async throws {
        let sms = PreviewSmsRepository(required: true, verifiedPhone: "+33612345678")
        let first = InvoiceViewModel(invoiceID: UUID(), repository: RecordingInvoices(), sms: sms)
        await first.load()
        await first.startSigning(asCompany: false)
        XCTAssertEqual(first.signingStep, .enterCode(maskedPhone: "+33 6 •• •• •• 78"))
        _ = try await sms.requestCode(.signInvoice, invoiceID: nil, phone: nil)   // the screen, reopened
        var sent = await sms.sent
        XCTAssertEqual(sent, 1, "the code still on its way is reused")
        let confirmed = try await first.confirmSigningCode(PreviewSmsRepository.demoCode)
        XCTAssertTrue(confirmed.ok)
        await first.codeConfirmed()

        let secondInvoices = RecordingInvoices()
        let second = InvoiceViewModel(invoiceID: UUID(), repository: secondInvoices, sms: sms)
        await second.load()
        await second.startSigning(asCompany: false)
        XCTAssertNil(second.signingStep, "no code screen at all")
        let signed = await secondInvoices.signatures
        XCTAssertEqual(signed, 1)
        sent = await sms.sent
        XCTAssertEqual(sent, 1, "two signatures, one SMS")
    }

    func testANumberIsShownTheWayItIsWritten() {
        XCTAssertEqual(MobileNumber.formatted("0612345678"), "06 12 34 56 78")
        XCTAssertEqual(MobileNumber.formatted("06123"), "06 12 3")
        XCTAssertEqual(MobileNumber.formatted("+44 7700"), "+44 7700")
    }

    @MainActor
    func testTheCompanySignsWithoutACode() async throws {
        let invoices = RecordingInvoices()
        let model = InvoiceViewModel(invoiceID: UUID(), repository: invoices,
                                     sms: PreviewSmsRepository(required: true))
        await model.load()
        await model.startSigning(asCompany: true)
        XCTAssertNil(model.signingStep)
        let signed = await invoices.signatures
        XCTAssertEqual(signed, 1)
    }

    /// The app sends the code's digits only, and to the function bound to
    /// this invoice; a wrong code comes back as an answer, not an error.
    func testTheCodeIsCheckedByTheServerForThisInvoice() async throws {
        let invoice = UUID()
        SmsCapture.requests = []
        SmsCapture.answer = { _ in #"{"ok":false,"reason":"wrong","message":"Code incorrect.","attempts_left":3}"# }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SmsCapture.self]
        let client = SupabaseClient(baseURL: URL(string: "https://project.supabase.co")!,
                                    anonKey: "anon", session: URLSession(configuration: configuration))
        let answer = try await SupabaseSmsRepository(client: client)
            .confirm(.signInvoice, code: "12 34 56", invoiceID: invoice)

        XCTAssertEqual(answer, SmsConfirmation(ok: false, reason: "wrong", message: "Code incorrect.",
                                               attemptsLeft: 3))
        XCTAssertFalse(answer.needsNewCode)
        let request = try XCTUnwrap(SmsCapture.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/confirm_sms_code")
        let body = try XCTUnwrap(SmsCapture.bodies.first)
        XCTAssertEqual(body["p_code"] as? String, "123456")
        XCTAssertEqual(body["p_purpose"] as? String, "sign_invoice")
        XCTAssertEqual(body["p_invoice_id"] as? String, invoice.uuidString)
    }

    func testAnSmsSignatureSaysSoOnTheDocument() async throws {
        var document = try await PreviewInvoiceRepository().document(invoiceID: UUID())
        document.signatures = [
            .init(role: "apporteur", name: "Johann Lefeuvre", signed: true, signedAt: .now,
                  smsVerified: true, smsPhone: "+33 6 •• •• •• 78"),
            .init(role: "entreprise", name: "Pierre-Louis Tettamanti", signed: true, signedAt: .now)
        ]
        let pdf = try XCTUnwrap(PDFDocument(data: InvoicePDF.render(document)))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            .components(separatedBy: .newlines).joined(separator: " ")   // the line wraps
        XCTAssertTrue(text.contains("Code SMS vérifié · +33 6 •• •• •• 78"), text)
        XCTAssertEqual(text.components(separatedBy: "Code SMS vérifié").count, 2,
                       "only the signature confirmed by SMS says so")
    }
}

/// An invoice repository that counts signatures.
private actor RecordingInvoices: InvoiceRepository {
    private(set) var signatures = 0

    func document(invoiceID: UUID) async throws -> InvoiceDocument {
        try await PreviewInvoiceRepository().document(invoiceID: invoiceID)
    }
    func latestInvoiceID(recommendationID: UUID) async throws -> UUID? { nil }
    func sign(invoiceID: UUID, documentSHA256: String) async throws { signatures += 1 }
    func pdf(for document: InvoiceDocument, invoiceID: UUID) async throws -> Data { Data() }
    func issue(recommendationID: UUID) async throws -> UUID { UUID() }
    func createCreditNote(invoiceID: UUID, reason: String) async throws -> UUID { UUID() }
}

private final class SmsCapture: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var answer: (URLRequest) -> String = { _ in "{}" }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.answer(request).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LegalTextTests: XCTestCase {
    func testTheContractsMarkdownBecomesHeadingsListsAndParagraphs() {
        let blocks = LegalText.parse("""
        **Entre les soussignés :**

        ## Article 1 — Objet

        Le Mandant donne mandat
        au Mandataire.

        - établir les factures ;
        - conserver un double.
        """)
        XCTAssertEqual(blocks, [
            .paragraph("**Entre les soussignés :**"),
            .heading("Article 1 — Objet"),
            .paragraph("Le Mandant donne mandat au Mandataire."),
            .bullet("établir les factures ;"),
            .bullet("conserver un double.")
        ])
        XCTAssertEqual(LegalText.parse("Article 2 — Obligations\n\nTexte."),
                       [.heading("Article 2 — Obligations"), .paragraph("Texte.")])
    }
}

final class DemoMandateTests: XCTestCase {
    /// Signing the mandate in the demo takes the notice away, as it does for real.
    /// (The demo store is shared across tests, so only the "after" is asserted.)
    func testSigningTheMandateInTheDemoRemovesTheNotice() async throws {
        let legal = PreviewLegalRepository()
        let documents = try await legal.documents()
        let mandate = try XCTUnwrap(documents.first { $0.key == "mandat_facturation" })
        try await legal.accept(key: mandate.key, sha256: mandate.sha256)

        let profile = try await PreviewProfileRepository().currentProfile()
        XCTAssertTrue(profile.canBeInvoiced, "the notice is gone once the mandate is signed")
    }
}
