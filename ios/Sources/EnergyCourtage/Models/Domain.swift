import Foundation

// MARK: - Roles

/// The app ships one binary for both populations; the role decides which
/// affordances appear (`Valider l'étape`, the action sheet, the company
/// signature panel). Authority itself is enforced in Postgres, never here.
public enum UserRole: String, Codable, Sendable {
    case apporteur, admin, manager

    public var isAdmin: Bool { self == .admin || self == .manager }
}

// MARK: - Pipeline

/// A pipeline stage. Mirrors `public.stages`: labels, banner copy and the
/// comment template are data, so the back-office can reword the funnel
/// without a new build.
public struct Stage: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let key: String
    public let label: String
    public let position: Int
    public let isRewardTrigger: Bool
    public let isTerminal: Bool
    public let bannerTemplate: String?
    public let commentTemplate: String?

    public init(id: UUID, key: String, label: String, position: Int,
                isRewardTrigger: Bool = false, isTerminal: Bool = false,
                bannerTemplate: String? = nil, commentTemplate: String? = nil) {
        self.id = id; self.key = key; self.label = label; self.position = position
        self.isRewardTrigger = isRewardTrigger; self.isTerminal = isTerminal
        self.bannerTemplate = bannerTemplate; self.commentTemplate = commentTemplate
    }
}

/// How a single step renders in the timeline.
///
/// The four cases are taken directly from the source app: a filled green check,
/// a hollow blue ring for the step in progress, a faint grey dot for what is
/// still ahead, and a failure state for a lost deal.
public enum StageState: Hashable, Sendable {
    case completed
    case current
    case pending
    case failed
}

/// One reached stage. `comment` is what the 💬 bubble opens; when it is nil the
/// bubble is not drawn at all — matching the in-progress card, where only
/// "À contacter" carries one.
public struct StageEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let stageID: UUID
    public let comment: String?
    public let completedAt: Date

    public init(id: UUID, stageID: UUID, comment: String?, completedAt: Date) {
        self.id = id; self.stageID = stageID
        self.comment = comment; self.completedAt = completedAt
    }
}

// MARK: - Recommendation

public enum RecommendationStatus: String, Codable, Sendable {
    case active, archivedWon = "archived_won", archivedLost = "archived_lost"

    public var isArchived: Bool { self != .active }
}

public enum RewardStatus: String, Codable, Sendable {
    case pending, earned, invoiced, paid, cancelled
}

public struct Recommendation: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// The recommended prospect. The source app calls them the *filleul*.
    public var filleulFirstName: String
    public var filleulLastName: String
    public var filleulPhone: String?
    /// Display name of the parrain — "Recommandé par Johann Lefeuvre".
    public var parrainName: String
    public var createdAt: Date
    public var currentStageID: UUID
    public var events: [StageEvent]
    public var rewardAmount: Decimal?
    public var rewardStatus: RewardStatus
    public var status: RecommendationStatus
    public var hasContract: Bool
    public var invoiceNumber: String?

    public var filleulName: String { "\(filleulFirstName) \(filleulLastName)" }

    public init(id: UUID, filleulFirstName: String, filleulLastName: String,
                filleulPhone: String? = nil, parrainName: String, createdAt: Date,
                currentStageID: UUID, events: [StageEvent] = [],
                rewardAmount: Decimal? = nil, rewardStatus: RewardStatus = .pending,
                status: RecommendationStatus = .active, hasContract: Bool = false,
                invoiceNumber: String? = nil) {
        self.id = id
        self.filleulFirstName = filleulFirstName
        self.filleulLastName = filleulLastName
        self.filleulPhone = filleulPhone
        self.parrainName = parrainName
        self.createdAt = createdAt
        self.currentStageID = currentStageID
        self.events = events
        self.rewardAmount = rewardAmount
        self.rewardStatus = rewardStatus
        self.status = status
        self.hasContract = hasContract
        self.invoiceNumber = invoiceNumber
    }

    // MARK: Derived presentation

    public func event(for stage: Stage) -> StageEvent? {
        events.first { $0.stageID == stage.id }
    }

    /// Resolves a stage to one of the four visual states.
    public func state(of stage: Stage, in pipeline: [Stage] = []) -> StageState {
        if status == .archivedLost, stage.id == currentStageID { return .failed }
        if event(for: stage) != nil { return .completed }
        return stage.id == currentStageID ? .current : .pending
    }

    /// The green banner text, derived from the stage the reco has reached —
    /// it is stage copy, not a free-text field on the recommendation.
    public func bannerText(in pipeline: [Stage]) -> String? {
        guard let reached = pipeline
            .filter({ event(for: $0) != nil })
            .max(by: { $0.position < $1.position }) else { return nil }
        return reached.bannerTemplate
    }

    /// The amount only surfaces once the reward has actually been triggered,
    /// which is why the in-progress card in the source app shows no figure.
    public var displayedAmount: Decimal? {
        rewardStatus == .pending ? nil : rewardAmount
    }
}
