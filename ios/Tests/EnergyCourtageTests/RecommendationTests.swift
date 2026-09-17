import XCTest
@testable import EnergyCourtage

/// Covers the presentation rules read off the screenshots — the ones that are
/// easy to get subtly wrong and invisible in a static mock.
final class RecommendationTests: XCTestCase {

    private let pipeline = SampleData.stages

    func testStepperStatesOnAnInProgressRecommendation() {
        let reco = SampleData.inProgressRecommendation
        XCTAssertEqual(reco.state(of: pipeline[0], in: pipeline), .completed)
        XCTAssertEqual(reco.state(of: pipeline[1], in: pipeline), .current)
        XCTAssertEqual(reco.state(of: pipeline[2], in: pipeline), .pending)
        XCTAssertEqual(reco.state(of: pipeline[4], in: pipeline), .pending)
    }

    func testEveryStageIsCompletedOnAFinishedRecommendation() {
        let reco = SampleData.completedRecommendation
        XCTAssertTrue(pipeline.allSatisfy { reco.state(of: $0, in: pipeline) == .completed })
    }

    /// The in-progress card in the source app shows no figure: the reward is
    /// only surfaced once it has actually been triggered.
    func testAmountIsHiddenWhileTheRewardIsPending() {
        XCTAssertNil(SampleData.inProgressRecommendation.displayedAmount)
        XCTAssertEqual(SampleData.completedRecommendation.displayedAmount, 1000)
    }

    func testBannerComesFromTheHighestReachedStage() {
        XCTAssertNil(SampleData.inProgressRecommendation.bannerText(in: pipeline))
        XCTAssertEqual(SampleData.completedRecommendation.bannerText(in: pipeline),
                       "Contrat signé. Disponible dans l'onglet Documents")
    }

    /// Only stages that carry a comment draw the 💬 bubble.
    func testCommentPresence() {
        let reco = SampleData.inProgressRecommendation
        XCTAssertNotNil(reco.event(for: pipeline[0])?.comment)
        XCTAssertNil(reco.event(for: pipeline[1]))
    }

    func testRelativeDateWording() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17,
                                                     hour: 22, minute: 54))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17,
                                                      hour: 14, minute: 57))!
        let older = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1,
                                                      hour: 9, minute: 5))!

        XCTAssertTrue(
            RecommendationCard.relativeDate(today, now: now, calendar: calendar)
                .hasPrefix("Aujourd'hui à")
        )
        XCTAssertTrue(
            RecommendationCard.relativeDate(older, now: now, calendar: calendar)
                .hasPrefix("01/09/2026 à")
        )
    }

    func testNextStageIsTheFirstUnreachedOne() async {
        let model = RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .admin
        )
        await model.load()
        let next = model.nextStage(for: SampleData.inProgressRecommendation)
        XCTAssertEqual(next?.key, "rdv_programme")
    }

    func testApporteurCannotAdvanceAStage() async {
        let model = RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .apporteur
        )
        await model.load()
        let before = model.recommendations.first { $0.id == SampleData.inProgressRecommendation.id }
        await model.validateNextStage(for: SampleData.inProgressRecommendation)
        let after = model.recommendations.first { $0.id == SampleData.inProgressRecommendation.id }
        XCTAssertEqual(before?.events.count, after?.events.count)
    }
}
