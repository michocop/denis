import SwiftUI

/// The vertical pipeline timeline.
///
/// Reproduces the source app's four node treatments and, importantly, the
/// connector rule: the segment between two steps is green only when the step
/// *above* it is completed, so the green thread stops exactly where progress
/// stops.
public struct StageStepper: View {

    public struct Row: Identifiable {
        public let id: UUID
        public let label: String
        public let state: StageState
        public let showsReward: Bool
        public let comment: String?

        public init(id: UUID, label: String, state: StageState,
                    showsReward: Bool, comment: String?) {
            self.id = id; self.label = label; self.state = state
            self.showsReward = showsReward; self.comment = comment
        }
    }

    private let rows: [Row]
    private let onComment: (Row) -> Void

    public init(rows: [Row], onComment: @escaping (Row) -> Void) {
        self.rows = rows
        self.onComment = onComment
    }

    private static let nodeSize: CGFloat = 32
    private static let connectorHeight: CGFloat = 30
    private static let connectorWidth: CGFloat = 3

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Row is Identifiable, so the loop takes it directly: Swift has no
            // key paths into tuples, which rules out the enumerated() idiom.
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    VStack(spacing: Theme.Spacing.xs) {
                        node(for: row.state)
                            .frame(width: Self.nodeSize, height: Self.nodeSize)
                        if row.id != rows.last?.id {
                            connector(below: row.state)
                        }
                    }
                    .frame(width: Self.nodeSize)

                    HStack(spacing: Theme.Spacing.s) {
                        Text(row.label)
                            .font(Theme.Typography.body)
                            .foregroundStyle(row.state == .pending
                                             ? Theme.Palette.textSecondary
                                             : Theme.Palette.textPrimary)

                        Spacer(minLength: Theme.Spacing.s)

                        if row.showsReward { RewardBadge() }

                        // No comment, no bubble — the source app hides it
                        // entirely rather than greying it out.
                        if row.comment != nil {
                            Button { onComment(row) } label: {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(Theme.Palette.brand)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Commentaire pour l'étape \(row.label)")
                        }
                    }
                    .frame(height: Self.nodeSize)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: row))
            }
        }
    }

    // MARK: - Node

    @ViewBuilder
    private func node(for state: StageState) -> some View {
        switch state {
        case .completed:
            Circle()
                .fill(Theme.Palette.success)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
        case .current:
            Circle()
                .fill(Theme.Palette.surface)
                .overlay { Circle().stroke(Theme.Palette.brand, lineWidth: 3) }
                .overlay {
                    Circle()
                        .fill(Theme.Palette.brand)
                        .frame(width: 11, height: 11)
                }
        case .pending:
            Circle()
                .fill(Theme.Palette.surface)
                .overlay { Circle().stroke(Theme.Palette.pendingRing, lineWidth: 1.5) }
                .overlay {
                    Circle()
                        .fill(Theme.Palette.pendingRing)
                        .frame(width: 7, height: 7)
                }
                .padding(2)
        case .failed:
            Circle()
                .fill(Theme.Palette.destructive)
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }

    /// Green only under a completed step.
    private func connector(below state: StageState) -> some View {
        Capsule()
            .fill(state == .completed ? Theme.Palette.success : Theme.Palette.connectorIdle)
            .frame(width: Self.connectorWidth, height: Self.connectorHeight)
    }

    private func accessibilityLabel(for row: Row) -> String {
        let status: String
        switch row.state {
        case .completed: status = "terminée"
        case .current:   status = "en cours"
        case .pending:   status = "à venir"
        case .failed:    status = "échouée"
        }
        return "\(row.label), étape \(status)"
    }
}

/// The 🎁 pill pinned to the reward-triggering stage. It is stage configuration,
/// so it shows whether or not that stage has been reached.
public struct RewardBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gift.fill").font(.system(size: 12))
            Text("Récompense").font(Theme.Typography.badge)
        }
        .foregroundStyle(Theme.Palette.rewardText)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.Palette.rewardSoft))
        .accessibilityLabel("Cette étape déclenche la récompense")
    }
}
