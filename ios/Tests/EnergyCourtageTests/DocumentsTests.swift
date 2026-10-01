import XCTest
@testable import EnergyCourtage

final class DocumentsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func item(_ number: String, kind: String = "honoraires", status: String = "signed",
                      daysAgo: Double = 1, active: Bool = true,
                      filleul: String = "Thomas Dubois") -> DocumentItem {
        DocumentItem(invoiceId: UUID(), number: number, kind: kind, status: status,
                     amountTtc: 100, issuedAt: now.addingTimeInterval(-daysAgo * 86_400),
                     filleulName: filleul, apporteurName: "Johann Lefeuvre",
                     recommendationActive: active, hasPdf: true)
    }

    func testEveryFilterStartsAtEverything() {
        let items = [item("FA-1"), item("FA-2", kind: "avoir", daysAgo: 400, active: false)]
        XCTAssertEqual(DocumentFilters().apply(to: items, now: now).count, 2)
    }

    func testFiltersNarrowIndependently() {
        let items = [
            item("FA-1", status: "awaiting_signatures"),
            item("FA-2", status: "paid", daysAgo: 45),
            item("FA-3", kind: "avoir", active: false, filleul: "Claire Moreau")
        ]
        var f = DocumentFilters()
        f.tag = .toSign
        XCTAssertEqual(f.apply(to: items, now: now).map(\.number), ["FA-1"])

        f = DocumentFilters(); f.period = .last30Days
        XCTAssertEqual(f.apply(to: items, now: now).map(\.number), ["FA-1", "FA-3"])

        f = DocumentFilters(); f.active = false
        XCTAssertEqual(f.apply(to: items, now: now).map(\.number), ["FA-3"])

        f = DocumentFilters(); f.kind = "avoir"
        XCTAssertEqual(f.apply(to: items, now: now).map(\.number), ["FA-3"])

        f = DocumentFilters(); f.query = "moreau"
        XCTAssertEqual(f.apply(to: items, now: now).map(\.number), ["FA-3"],
                       "search covers the filleul's name, whatever the case")
    }

    func testDocumentsAreNamedAsOnThePaper() {
        XCTAssertEqual(item("FA-1").title, "Reconnaissance d'honoraires")
        XCTAssertEqual(item("FA-1", kind: "avoir").title, "Avoir")
    }

    func testTheAmountReadsTheFrenchWay() {
        let text = SignatureCodeDialog.euros("1300.00")
        XCTAssertTrue(text.contains("300,00") && text.contains("€"), text)
    }

    func testJustificatifKindsMatchTheDatabase() {
        XCTAssertEqual(JustificatifKind.allCases.map(\.rawValue), ["carte_identite", "rib"])
    }
}
