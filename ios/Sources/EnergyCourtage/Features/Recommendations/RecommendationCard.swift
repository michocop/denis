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
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                Text(initials)
                    .font(Theme.Typography.badge)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(Theme.Palette.avatar, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Palette.brand.opacity(0.35), lineWidth: 1))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.filleulName)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Par \(recommendation.parrainName) · \(Self.relativeDay(recommendation.createdAt))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.s)

                Button {
                    withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 32, height: 32)
                        .background(Theme.Palette.grouped, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Réduire" : "Développer")
            }

            // where the lead stands, at a glance
            HStack(spacing: Theme.Spacing.m) {
                if let stage = currentStageLabel {
                    Text(stage)
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(stageTint)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(stageTint.opacity(0.14), in: Capsule())
                }
                ProgressView(value: progress)
                    .tint(stageTint)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Avancement \(Int(progress * 100)) %")
                if let amount = recommendation.displayedAmount {
                    Text(Money.euros(amount))
                        .font(Theme.Typography.amount)
                        .foregroundStyle(Theme.Palette.successText)
                        .accessibilityLabel("Récompense \(Money.euros(amount))")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
        }
    }

    /// "Aujourd'hui", "Hier" or "17/09": the time is in the detail.
    static func relativeDay(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDate(date, inSameDayAs: now) { return "Aujourd'hui" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Hier" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "dd/MM" : "dd/MM/yy"
        return f.string(from: date)
    }

    private var initials: String {
        recommendation.filleulName.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var orderedPipeline: [Stage] { pipeline.sorted { $0.position < $1.position } }

    private var progress: Double {
        guard !orderedPipeline.isEmpty else { return 0 }
        let done = orderedPipeline.filter { recommendation.state(of: $0, in: pipeline) == .completed }.count
        return Double(done) / Double(orderedPipeline.count)
    }

    private var currentStageLabel: String? {
        if recommendation.status.isArchived { return "Archivée" }
        if orderedPipeline.contains(where: { recommendation.state(of: $0, in: pipeline) == .failed }) {
            return "Non abouti"
        }
        return orderedPipeline.first { recommendation.state(of: $0, in: pipeline) == .current }?.label
            ?? (progress >= 1 ? "Terminée" : nil)
    }

    private var stageTint: Color {
        if orderedPipeline.contains(where: { recommendation.state(of: $0, in: pipeline) == .failed }) {
            return Theme.Palette.destructive
        }
        return progress >= 1 ? Theme.Palette.successText : Theme.Palette.brand
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
