import XCTest
@testable import EnergyCourtage

/// The demo is how the app is shown to prospects and to Apple's reviewers, so
/// what it lets you do has to hold: a step validated stays validated, a signed
/// mandate stops being asked for, and tickets stay visible whatever the filter.
final class DemoTests: XCTestCase {

    /// Each validation used to start again from the untouched sample, so the
    /// second one lost the first and "Devis signé" could never be reached.
    func testValidatingStepByStepWalksThePipelineToItsEnd() async throws {
        let repository = PreviewRecommendationsRepository()
        let model = RecommendationsViewModel(repository: repository, role: .admin)
        await model.load()
        let id = SampleData.inProgressRecommendation.id

        for _ in 0..<SampleData.stages.count {
            guard let reco = model.recommendations.first(where: { $0.id == id }),
                  model.nextStage(for: reco) != nil else { break }
            await model.validateNextStage(for: reco)
        }

        let reco = try XCTUnwrap(model.recommendations.first { $0.id == id })
        XCTAssertNil(model.nextStage(for: reco), "every stage is reached, Devis signé included")
        XCTAssertEqual(reco.rewardStatus, .earned)

        // and the progress survives a reload, as it would from the server
        await model.load()
        let reloaded = try XCTUnwrap(model.recommendations.first { $0.id == id })
        XCTAssertNil(model.nextStage(for: reloaded))
    }

    func testAClosedDealLeavesTheActiveList() async throws {
        let repository = PreviewRecommendationsRepository()
        try await repository.archive(recommendationID: SampleData.inProgressRecommendation.id, won: false)
        let active = try await repository.loadPage(archived: false, search: "", cursor: nil)
        let archived = try await repository.loadPage(archived: true, search: "", cursor: nil)
        XCTAssertFalse(active.contains { $0.id == SampleData.inProgressRecommendation.id })
        XCTAssertTrue(archived.contains { $0.id == SampleData.inProgressRecommendation.id })
    }

    /// "Groupes" picked on Discussions, then Tickets: the list used to be empty.
    func testTicketsShowWhateverFilterWasLeftOnDiscussions() async {
        let model = ChatViewModel(repository: PreviewChatRepository(),
                                  profiles: PreviewProfileRepository(role: .admin))
        await model.load()
        model.filter = .groups
        model.tab = .tickets
        XCTAssertFalse(model.visibleThreads.isEmpty)
        XCTAssertFalse(model.availableFilters.contains(.groups))
    }

    /// The notice on Accueil goes once the mandate is signed.
    func testSigningTheDemoMandateStopsItBeingAskedFor() async throws {
        await DemoLegalStore.shared.reset()
        let before = try await PreviewProfileRepository().currentProfile()
        XCTAssertFalse(before.canBeInvoiced)

        let legal = LegalViewModel(repository: PreviewLegalRepository())
        await legal.load()
        let mandate = try XCTUnwrap(legal.mandate)
        await legal.accept(mandate)
        let profile = try await PreviewProfileRepository().currentProfile()
        await DemoLegalStore.shared.reset()   // other tests expect an unsigned demo
        XCTAssertTrue(profile.canBeInvoiced)
    }
}
