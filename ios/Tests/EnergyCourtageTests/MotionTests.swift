import XCTest
@testable import EnergyCourtage

/// The rules behind the motion layer that a screenshot cannot show: when the
/// opening may leave, how far a cascade reaches, and which events are worth a
/// vibration.
final class MotionTests: XCTestCase {

    // MARK: - Opening

    /// A slow network: the animation ends first, and the logo breathes until
    /// the session is known rather than handing over to an empty screen.
    func testTheOpeningWaitsForTheSessionOnceItHasPlayed() {
        var gate = LaunchGate()
        gate.animationFinished()
        XCTAssertTrue(gate.isWaiting)
        XCTAssertFalse(gate.canLeave)

        gate.sessionResolved()
        XCTAssertFalse(gate.isWaiting)
        XCTAssertTrue(gate.canLeave)
    }

    /// A fast network: the session is known before the animation ends, and the
    /// animation still plays out instead of being cut mid-pulse.
    func testTheOpeningPlaysToTheEndWhenTheSessionIsQuick() {
        var gate = LaunchGate()
        gate.sessionResolved()
        XCTAssertFalse(gate.isWaiting)
        XCTAssertFalse(gate.canLeave)

        gate.animationFinished()
        XCTAssertTrue(gate.canLeave)
    }

    func testTheLaunchingPhaseIsTheOnlyOneThatHoldsTheOpening() {
        XCTAssertTrue(AppModel.Phase.launching.isLaunching)
        XCTAssertFalse(AppModel.Phase.signedOut(nil).isLaunching)
        XCTAssertFalse(AppModel.Phase.locked.isLaunching)
    }

    // MARK: - Cascades

    func testACascadeStartsAtOnceAndStepsEvenly() {
        XCTAssertEqual(Motion.staggerDelay(index: 0), 0)
        XCTAssertEqual(Motion.staggerDelay(index: 1), Motion.staggerStep, accuracy: 1e-9)
        XCTAssertEqual(Motion.staggerDelay(index: 3), 3 * Motion.staggerStep, accuracy: 1e-9)
    }

    /// Forty cards arriving one after another would take seconds; past the
    /// first screenful they all arrive together.
    func testACascadeIsCappedSoALongListDoesNotTrickleIn() {
        let cap = Motion.staggerDelay(index: Motion.staggerLimit)
        XCTAssertEqual(Motion.staggerDelay(index: 40), cap, accuracy: 1e-9)
        XCTAssertLessThan(cap, 0.5)
    }

    // MARK: - Feedback

    func testValidatingAStageIsCountedSoTheScreenCanCelebrateIt() async {
        let model = RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .admin
        )
        await model.load()
        await model.validateNextStage(for: SampleData.inProgressRecommendation)
        XCTAssertEqual(model.stageAdvances, 1)
    }

    /// No success vibration for something that did not happen.
    func testARefusedAdvanceIsNotCounted() async {
        let model = RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .apporteur
        )
        await model.load()
        await model.validateNextStage(for: SampleData.inProgressRecommendation)
        XCTAssertEqual(model.stageAdvances, 0)
    }

    func testAnAcceptedDocumentIsCounted() async {
        let model = LegalViewModel(repository: PreviewLegalRepository())
        await model.load()
        guard let document = model.documents.first(where: { !$0.accepted }) else {
            return XCTFail("the sample data should hold a document still to accept")
        }
        await model.accept(document)
        XCTAssertEqual(model.acceptances, 1)
    }
}
