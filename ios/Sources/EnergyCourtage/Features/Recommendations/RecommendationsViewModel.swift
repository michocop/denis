import Foundation
import Observation

/// Abstraction over the data source so the screen can be driven by a fake in
/// previews and tests, and by Supabase in the app.
public protocol RecommendationsRepository: Sendable {
    func loadPipeline() async throws -> [Stage]
    /// One page, newest first. `cursor` is the last row already shown; passing
    /// nil asks for the first page.
    func loadPage(archived: Bool, search: String,
                  cursor: RecommendationCursor?) async throws -> [Recommendation]
    func advanceStage(recommendationID: UUID, stageKey: String) async throws -> Recommendation

    // Creation, and the five admin powers behind the action sheet.
    func create(_ draft: RecommendationDraft) async throws -> Recommendation
    func reassign(recommendationID: UUID, to adminID: UUID) async throws
    /// The commission the apporteur will be paid. Admin only, and refused once
    /// an invoice exists, because the invoice carries a copy of it.
    func setRewardAmount(recommendationID: UUID, amount: Decimal) async throws
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
    func setRewardAmount(recommendationID: UUID, amount: Decimal) async throws {}
    func archive(recommendationID: UUID, won: Bool) async throws {}
    func resetPipeline(recommendationID: UUID) async throws {}
    func softDelete(recommendationID: UUID) async throws {}
    func loadAdmins() async throws -> [Profile] { [] }
}

/// Where the last page stopped. A position in the ordering rather than a row
/// count, so rows arriving while someone reads cannot make the next page skip
/// or repeat entries -- which is exactly what OFFSET does.
public struct RecommendationCursor: Hashable, Sendable {
    public let createdAt: Date
    public let id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }
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
    public private(set) var isLoadingMore = false
    public private(set) var hasMorePages = true
    private var searchTask: Task<Void, Never>?
    private static let pageSize = 20

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

    /// Search runs on the server, against an index. Filtering in Swift meant
    /// downloading every recommendation first, which is fine for a demo and
    /// hopeless for an admin with forty thousand of them.
    public var visibleRecommendations: [Recommendation] { recommendations }

    public var isEmpty: Bool {
        state == .loaded && visibleRecommendations.isEmpty
    }

    @MainActor
    public func load() async {
        state = .loading
        do {
            async let pipelineTask = repository.loadPipeline()
            async let pageTask = repository.loadPage(
                archived: filter.isArchived, search: trimmedQuery, cursor: nil
            )
            pipeline = try await pipelineTask
            recommendations = try await pageTask
            hasMorePages = recommendations.count == Self.pageSize
            hasStaleData = false
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called when the last visible card appears. Guarded against re-entry,
    /// because a fast scroll fires it several times before the first returns.
    @MainActor
    public func loadNextPageIfNeeded(currentItem: Recommendation) async {
        guard hasMorePages, !isLoadingMore,
              currentItem.id == recommendations.last?.id,
              let last = recommendations.last else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let cursor = RecommendationCursor(createdAt: last.createdAt, id: last.id)
        do {
            let page = try await repository.loadPage(
                archived: filter.isArchived, search: trimmedQuery, cursor: cursor
            )
            // De-duplicate: a row edited between pages can appear twice.
            let known = Set(recommendations.map(\.id))
            recommendations.append(contentsOf: page.filter { !known.contains($0.id) })
            hasMorePages = page.count == Self.pageSize
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Debounced so typing a name is one request, not one per keystroke.
    @MainActor
    public func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.load()
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
