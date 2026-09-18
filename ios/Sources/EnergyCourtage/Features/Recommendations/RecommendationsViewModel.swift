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

    /// Warns before a second apporteur claims a lead someone already holds.
    func checkDuplicate(phone: String, email: String) async throws -> DuplicateCheck
    func note(recommendationID: UUID) async throws -> String
    func saveNote(recommendationID: UUID, body: String) async throws
}

/// Deliberately says only *that* a lead is held, never by whom: an apporteur
/// must be warned without being handed a competitor's pipeline.
public struct DuplicateCheck: Hashable, Codable, Sendable {
    public var alreadyYours: Bool
    public var heldBySomeoneElse: Bool

    public init(alreadyYours: Bool = false, heldBySomeoneElse: Bool = false) {
        self.alreadyYours = alreadyYours
        self.heldBySomeoneElse = heldBySomeoneElse
    }

    public var warning: String? {
        if alreadyYours { return Strings.Duplicate.alreadyYours }
        if heldBySomeoneElse { return Strings.Duplicate.heldByAnother }
        return nil
    }

    /// A lead already in your own list is a mistake worth blocking; one held by
    /// someone else is a judgement call that stays the apporteur's to make.
    public var blocksSubmission: Bool { alreadyYours }
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
    func checkDuplicate(phone: String, email: String) async throws -> DuplicateCheck {
        DuplicateCheck()
    }
    func note(recommendationID: UUID) async throws -> String { "" }
    func saveNote(recommendationID: UUID, body: String) async throws {}
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
    private let changeMonitor: ChangeMonitor
    private var watchTask: Task<Void, Never>?

    public init(repository: RecommendationsRepository, role: UserRole,
                changeMonitor: ChangeMonitor = InertChangeMonitor()) {
        self.repository = repository
        self.role = role
        self.changeMonitor = changeMonitor
    }

    deinit { watchTask?.cancel() }

    /// Watches for server-side changes and raises the banner rather than
    /// reloading underneath whatever the user is reading.
    @MainActor
    public func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self, changeMonitor] in
            for await _ in changeMonitor.changes() {
                guard let self else { return }
                await MainActor.run { self.hasStaleData = true }
            }
        }
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

    @MainActor
    public func report(_ error: Error) {
        state = .failed(error.localizedDescription)
    }

    public func stage(with id: UUID) -> Stage? {
        pipeline.first { $0.id == id }
    }
}
