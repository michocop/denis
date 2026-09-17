import Foundation
import Observation

/// Abstraction over the data source so the screen can be driven by a fake in
/// previews and tests, and by Supabase in the app.
public protocol RecommendationsRepository: Sendable {
    func loadPipeline() async throws -> [Stage]
    func loadRecommendations(archived: Bool) async throws -> [Recommendation]
    func advanceStage(recommendationID: UUID, stageKey: String) async throws -> Recommendation
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

    public var filter: RecommendationFilter = .active { didSet { Task { await load() } } }
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
