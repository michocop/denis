import SwiftUI

/// The expandable recommendation card.
///
/// Collapsed it shows identity, referrer, timestamp and — only once the reward
/// has been triggered — the green amount. Expanded it reveals the status
/// banner, the timeline and the footer actions, which differ by role: an
/// apporteur reads, an admin gets `Valider l'étape`.
public struct RecommendationCard: View {

    private let recommendation: Recommendation
    private let pipeline: [Stage]
    private let role: UserRole
    @Binding private var isExpanded: Bool

    private let onComment: (StageStepper.Row) -> Void
    private let onNotes: () -> Void
    private let onContract: () -> Void
    private let onMore: () -> Void
    private let onValidate: () -> Void

    public init(recommendation: Recommendation,
                pipeline: [Stage],
                role: UserRole,
                isExpanded: Binding<Bool>,
                onComment: @escaping (StageStepper.Row) -> Void,
                onNotes: @escaping () -> Void,
                onContract: @escaping () -> Void,
                onMore: @escaping () -> Void,
                onValidate: @escaping () -> Void) {
        self.recommendation = recommendation
        self.pipeline = pipeline
        self.role = role
        self._isExpanded = isExpanded
        self.onComment = onComment
        self.onNotes = onNotes
        self.onContract = onContract
        self.onMore = onMore
        self.onValidate = onValidate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            header

            if isExpanded {
                if let banner = recommendation.bannerText(in: pipeline) {
                    StatusBanner(banner)
                }

                StageStepper(rows: stepperRows, onComment: onComment)

                footer
            }
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.filleulName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Recommandé par \(recommendation.parrainName)")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(Self.relativeDate(recommendation.createdAt))
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            Spacer(minLength: Theme.Spacing.s)

            if let amount = recommendation.displayedAmount {
                Text(Self.currency.string(from: amount as NSDecimalNumber) ?? "")
                    .font(Theme.Typography.amount)
                    .foregroundStyle(Theme.Palette.successText)
                    .accessibilityLabel("Récompense \(amount) euros")
            }

            Button {
                withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : 180))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Réduire" : "Développer")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Theme.Spacing.m) {
            SecondaryActionButton("Notes personnelles", systemImage: "doc", action: onNotes)

            if recommendation.hasContract {
                SecondaryActionButton("Voir le contrat", systemImage: "doc.text",
                                      action: onContract)
            }

            if role.isAdmin && !recommendation.status.isArchived && !isPipelineComplete {
                HStack(spacing: Theme.Spacing.m) {
                    TertiaryActionButton("Voir plus", action: onMore)
                    PrimaryActionButton("Valider l'étape", action: onValidate)
                }
            } else {
                TertiaryActionButton("Voir plus", action: onMore)
            }
        }
    }

    // MARK: - Derived

    private var isPipelineComplete: Bool {
        guard let last = pipeline.max(by: { $0.position < $1.position }) else { return false }
        return recommendation.event(for: last) != nil
    }

    private var stepperRows: [StageStepper.Row] {
        pipeline
            .sorted { $0.position < $1.position }
            .map { stage in
                StageStepper.Row(
                    id: stage.id,
                    label: stage.label,
                    state: recommendation.state(of: stage, in: pipeline),
                    showsReward: stage.isRewardTrigger,
                    comment: recommendation.event(for: stage)?.comment
                )
            }
    }

    // MARK: - Formatting

    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "fr_FR")
        f.maximumFractionDigits = 0
        // The source app renders "1000 €", not the French default "1 000 €".
        f.usesGroupingSeparator = false
        return f
    }()

    /// "Aujourd'hui à 14:57" for today, otherwise "17/09/2026 à 14:57" —
    /// both spellings appear in the source app.
    static func relativeDate(_ date: Date, now: Date = .now,
                             calendar: Calendar = .current) -> String {
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Aujourd'hui à \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Hier à \(time)"
        }
        return "\(dayFormatter.string(from: date)) à \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()
}
