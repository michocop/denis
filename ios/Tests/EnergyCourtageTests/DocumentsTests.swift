import XCTest
import PDFKit
import UIKit
@testable import EnergyCourtage

final class DocumentsTests: XCTestCase {

    private func photo(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: 40, y: 40, width: width / 2, height: 60))
        }
    }

    /// A full-resolution phone photo is shrunk before it is sent.
    func testAPhotoOfABillIsResizedAndSentAsJPEG() throws {
        let original = try XCTUnwrap(photo(width: 4032, height: 3024).pngData())
        let upload = try XCTUnwrap(DocumentSources.upload(fromImageData: original, name: "Facture"))
        XCTAssertEqual(upload.mimeType, "image/jpeg")
        XCTAssertEqual(upload.filename, "Facture.jpg")
        XCTAssertEqual(upload.kind, "energy_bill")
        let image = try XCTUnwrap(UIImage(data: upload.data))
        XCTAssertEqual(max(image.size.width, image.size.height), 2400, accuracy: 1)
        XCTAssertLessThan(upload.data.count, original.count)
    }

    /// Scanned pages become one PDF, a page each, as an accountant expects.
    func testScannedPagesBecomeOnePDF() throws {
        let upload = try XCTUnwrap(DocumentSources.upload(fromScannedPages: [
            photo(width: 1240, height: 1754), photo(width: 1240, height: 1754)
        ]))
        XCTAssertEqual(upload.mimeType, "application/pdf")
        XCTAssertTrue(upload.filename.hasPrefix("Facture scannée"))
        XCTAssertEqual(PDFDocument(data: upload.data)?.pageCount, 2)
    }

    func testAFileOverTenMegabytesIsRefusedBeforeItIsSent() async {
        let repository = PreviewDocumentsRepository()
        let huge = DocumentUpload(data: Data(count: DocumentUpload.maxBytes + 1),
                                  filename: "x.pdf", mimeType: "application/pdf")
        do {
            _ = try await repository.add(huge, to: UUID())
            XCTFail("a file over the limit must be refused")
        } catch {
            XCTAssertEqual(error as? DocumentError, .tooLarge)
        }
    }

    /// Bytes first, under the lead's own folder, then the row that lists them.
    func testUploadingStoresTheFileUnderItsLeadThenRegistersIt() async throws {
        let lead = UUID()
        DocumentCapture.requests = []
        DocumentCapture.answer = { request in
            request.url!.path.contains("register_document")
                ? #"{"id":"\#(UUID().uuidString)","recommendation_id":"\#(lead.uuidString)","kind":"energy_bill","storage_path":"p","filename":"f.pdf","byte_size":4,"mime_type":"application/pdf","uploaded_by":"\#(UUID().uuidString)","created_at":"2026-10-04T10:00:00Z"}"#
                : "{}"
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DocumentCapture.self]
        let client = SupabaseClient(baseURL: URL(string: "https://project.supabase.co")!,
                                    anonKey: "anon", session: URLSession(configuration: configuration))
        let repository = SupabaseDocumentsRepository(client: client)

        let added = try await repository.add(
            DocumentUpload(data: Data("%PDF".utf8), filename: "f.pdf", mimeType: "application/pdf"),
            to: lead)

        XCTAssertEqual(added.recommendationId, lead)
        let paths = DocumentCapture.requests.map { $0.url!.path }
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].hasPrefix("/storage/v1/object/documents/\(lead.uuidString.lowercased())/"),
                      "the file goes under its lead, which is what decides who may read it")
        XCTAssertTrue(paths[0].hasSuffix(".pdf"))
        XCTAssertEqual(paths[1], "/rest/v1/rpc/register_document")
    }
}

private final class DocumentCapture: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var answer: (URLRequest) -> String = { _ in "{}" }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.answer(request).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
