import Foundation

// MARK: - Reward stage

/// How the reward is paid. Mirrors `public.payout_method`; the labels are the
/// ones the validation screen lists and the invoice prints.
public enum PayoutMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case virement
    case cheque
    case carteCadeau = "carte_cadeau"
    case avoirFacture = "avoir_facture"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .virement:     return "Virement bancaire"
        case .cheque:       return "Chèque"
        case .carteCadeau:  return "Carte cadeau"
        case .avoirFacture: return "Avoir sur facture"
        }
    }
}

/// One service the filleul took, as edited on "Validation de l'étape".
/// Amounts are kept as the text typed, so "1 300,50" can be entered the
/// French way without the field reformatting under the cursor; the numbers
/// are read from it when needed.
public struct RewardLineDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public var turnoverText: String
    public var rewardText: String
    public var signed: Bool

    public init(id: UUID = UUID(), label: String = "", turnover: Decimal? = nil,
                reward: Decimal? = nil, signed: Bool = true) {
        self.id = id; self.label = label; self.signed = signed
        self.turnoverText = turnover.map(RewardLineDraft.text) ?? ""
        self.rewardText = reward.map(RewardLineDraft.text) ?? ""
    }

    public var turnover: Decimal? { Self.parse(turnoverText) }
    public var reward: Decimal? { Self.parse(rewardText) }

    /// A field that holds something that is not a number.
    public var hasInvalidAmount: Bool {
        (!turnoverText.trimmingCharacters(in: .whitespaces).isEmpty && turnover == nil)
        || (!rewardText.trimmingCharacters(in: .whitespaces).isEmpty && reward == nil)
    }

    public var isBlank: Bool {
        label.trimmingCharacters(in: .whitespaces).isEmpty
        && turnoverText.trimmingCharacters(in: .whitespaces).isEmpty
        && rewardText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "1 300,50", "1300.5", "1 300" -> 1300.5. Negative or malformed -> nil.
    public static func parse(_ text: String) -> Decimal? {
        let cleaned = text
            .filter { !$0.isWhitespace && $0 != "\u{202F}" && $0 != "\u{00A0}" }
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty,
              cleaned.range(of: #"^[0-9]+(\.[0-9]{0,2})?$"#, options: .regularExpression) != nil
        else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func text(_ amount: Decimal) -> String {
        "\(amount)".replacingOccurrences(of: ".", with: ",")
    }
}

/// The totals are derived, never typed: the ticked services decide them, which
/// is what "Calculé à partir des prestations cochées" promises.
public struct RewardStageForm: Hashable, Sendable {
    public var lines: [RewardLineDraft]
    public var message: String = ""
    public var payoutMethod: PayoutMethod = .virement
    public var maxReward: Decimal

    public init(lines: [RewardLineDraft] = [RewardLineDraft()], maxReward: Decimal = 2000) {
        self.lines = lines.isEmpty ? [RewardLineDraft()] : lines
        self.maxReward = maxReward
    }

    public var turnoverTotal: Decimal {
        lines.filter(\.signed).reduce(0) { $0 + ($1.turnover ?? 0) }
    }

    public var rewardTotal: Decimal {
        lines.filter(\.signed).reduce(0) { $0 + ($1.reward ?? 0) }
    }

    /// Why "Valider l'étape" is not available yet, or nil when it is. The
    /// server applies the same rules; this only saves a round trip.
    public var problem: String? {
        let used = lines.filter { !$0.isBlank }
        if used.isEmpty { return "Ajoutez au moins une prestation." }
        if let index = lines.firstIndex(where: {
            !$0.isBlank && $0.label.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            return "Prestation \(index + 1) : indiquez l'intitulé."
        }
        if let index = lines.firstIndex(where: \.hasInvalidAmount) {
            return "Prestation \(index + 1) : montant invalide."
        }
        if rewardTotal <= 0 { return "Cochez au moins une prestation signée avec une récompense." }
        if rewardTotal > maxReward {
            return "La récompense dépasse le montant maximum de \(RewardStageForm.format(maxReward)) EUR."
        }
        return nil
    }

    /// The lines as sent: blank rows the admin added and never filled are dropped.
    public var submittedLines: [RewardLineDraft] { lines.filter { !$0.isBlank } }

    public static func format(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}

/// What `reward_breakdown` returns: the lines a reward was made of, so the
/// screen can reopen with them ticked as they were.
public struct RewardBreakdown: Decodable, Hashable, Sendable {
    public struct Line: Decodable, Hashable, Sendable {
        public let label: String
        public let turnover: Decimal
        public let reward: Decimal
        public let signed: Bool
    }

    public let turnoverAmount: Decimal?
    public let rewardAmount: Decimal?
    public let payoutMethod: PayoutMethod?
    public let maxReward: Decimal
    public let lines: [Line]

    public init(turnoverAmount: Decimal? = nil, rewardAmount: Decimal? = nil,
                payoutMethod: PayoutMethod? = nil, maxReward: Decimal = 2000,
                lines: [Line] = []) {
        self.turnoverAmount = turnoverAmount; self.rewardAmount = rewardAmount
        self.payoutMethod = payoutMethod; self.maxReward = maxReward; self.lines = lines
    }
}

/// The stage comment screen opens on the stage's own wording, filled in, so
/// most of the time validating is one tap. Same placeholders as the
/// server-side render_template().
public enum StageCommentTemplate {
    public static func render(_ template: String?, for recommendation: Recommendation) -> String {
        guard let template else { return "" }
        let parrain = recommendation.parrainName.split(separator: " ").first.map(String.init)
            ?? recommendation.parrainName
        let amount = recommendation.rewardAmount.map { RewardStageForm.format($0) } ?? ""
        return template
            .replacingOccurrences(of: "{filleul}", with: recommendation.filleulName)
            .replacingOccurrences(of: "{parrain}", with: parrain)
            .replacingOccurrences(of: "{montant}", with: amount)
    }
}
