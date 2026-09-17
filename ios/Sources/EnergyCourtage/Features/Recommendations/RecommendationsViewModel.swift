import Foundation
import Observation

/// Abstraction over the data source so the screen can be driven by a fake in
/// previews and tests, and by Supabase in the app.
public protocol RecommendationsRepository: Sendable {
    func loadPipeline() async throws -> [Stage]
    func loadRecommendations(archived: Bool) async throws -> [Recommendation]
    func advanceStage(recommendationID: UUID, stageKey: String) async throws -> Recommendation

    // Creation, and the five admin powers behind the action sheet.
    func create(_ draft: RecommendationDraft) async throws -> Recommendation
    func reassign(recommendationID: UUID, to adminID: UUID) async throws
    func archive(recommendationID: UUID, won: Bool) async throws
    func resetPipeline(recommendationID: UUID) async throws
    func softDelete(recommendationID: UUID) async throws
    func loadAdmins() async throws -> [Profile]
}

/// What the create form collects. `consentConfirmed` is not decoration: the
/// filleul never signed up, so storing their details needs a lawful basis and
/// the apporteur confirming they informed them is it.
public struct RecommendationDraft: Hashable, Sendable {
    public var firstName: String = ""
    public var lastName: String = ""
    public var phone: String = ""
    public var email: String = ""
    public var company: String = ""
    public var offerID: UUID?
    public var consentConfirmed: Bool = false

    public init() {}

    public var isValid: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
        && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
        && !phone.trimmingCharacters(in: .whitespaces).isEmpty
        && consentConfirmed
    }
}

/// Previews and tests only need the read path; the admin operations default to
/// no-ops so a fake does not have to implement six methods it never calls.
public extension RecommendationsRepository {
    func reassign(recommendationID: UUID, to adminID: UUID) async throws {}
    func archive(recommendationID: UUID, won: Bool) async throws {}
    func resetPipeline(recommendationID: UUID) async throws {}
    func softDelete(recommendationID: UUID) async throws {}
    func loadAdmins() async throws -> [Profile] { [] }
}

public enum RecommendationFilter: Hashable, Sendable {
    case active, archived

    var isArchived: Bool { self == .archived }
}

@Observable
public final class RecommendationsViewModel {

    public enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    public private(set) var state: LoadState = .idle
    public private(set) var pipeline: [Stage] = []
    public private(set) var recommendations: [Recommendation] = []
    /// Set by the realtime channel; drives the "Actualiser" banner rather than
    /// reloading the list under the user's finger.
    public var hasStaleData = false

    // No didSet here: the @Observable macro rewrites stored properties, and
    // property observers do not survive it. The view reloads on change instead.
    public var filter: RecommendationFilter = .active
    public var query: String = ""
    public var expandedID: UUID?

    public let role: UserRole
    private let repository: RecommendationsRepository

    public init(repository: RecommendationsRepository, role: UserRole) {
        self.repository = repository
        self.role = role
    }

    /// Search covers the filleul and the parrain, which is what the source
    /// app's single field implies.
    public var visibleRecommendations: [Recommendation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recommendations }
        return recommendations.filter {
            $0.filleulName.localizedCaseInsensitiveContains(trimmed)
            || $0.parrainName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public var isEmpty: Bool {
        state == .loaded && visibleRecommendations.isEmpty
    }

    @MainActor
    public func load() async {
        state = .loading
        do {
            async let pipelineTask = repository.loadPipeline()
            async let recosTask = repository.loadRecommendations(archived: filter.isArchived)
            pipeline = try await pipelineTask
            recommendations = try await recosTask
            hasStaleData = false
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @MainActor
    public func refresh() async {
        hasStaleData = false
        await load()
    }

    /// `Valider l'étape` — advances to the next stage that has not been reached.
    @MainActor
    public func validateNextStage(for recommendation: Recommendation) async {
        guard role.isAdmin, let next = nextStage(for: recommendation) else { return }
        do {
            let updated = try await repository.advanceStage(
                recommendationID: recommendation.id, stageKey: next.key
            )
            if let index = recommendations.firstIndex(where: { $0.id == updated.id }) {
                recommendations[index] = updated
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func nextStage(for recommendation: Recommendation) -> Stage? {
        pipeline
            .sorted { $0.position < $1.position }
            .first { recommendation.event(for: $0) == nil }
    }

    public func stage(with id: UUID) -> Stage? {
        pipeline.first { $0.id == id }
    }
}
