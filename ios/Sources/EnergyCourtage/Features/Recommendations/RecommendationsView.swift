import SwiftUI

/// The `Recommandations` tab.
public struct RecommendationsView: View {

    @State private var model: RecommendationsViewModel
    @State private var presentedComment: PresentedComment?

    private struct PresentedComment: Identifiable {
        let id = UUID()
        let stageLabel: String
        let message: String
    }

    public init(model: RecommendationsViewModel) {
        _model = State(wrappedValue: model)
    }

    public var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Recommandations")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    SegmentedPicker(
                        selection: $model.filter,
                        options: [.init(.active, "Actives"), .init(.archived, "Archivées")]
                    )

                    SearchField("Rechercher...", text: $model.query)

                    if model.hasStaleData {
                        RefreshBanner { Task { await model.refresh() } }
                    }

                    content
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refresh() }

            if let comment = presentedComment {
                StageCommentDialog(stageLabel: comment.stageLabel,
                                   message: comment.message) {
                    withAnimation(.snappy(duration: 0.2)) { presentedComment = nil }
                }
                .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.25), value: model.hasStaleData)
        .task { await model.load() }
        .onChange(of: model.filter) { _, _ in Task { await model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in SkeletonCard() }

        case .failed(let message):
            ErrorState(message: message) { Task { await model.load() } }

        case .loaded:
            if model.isEmpty {
                EmptyState(filter: model.filter, hasQuery: !model.query.isEmpty)
            } else {
                ForEach(model.visibleRecommendations) { reco in
                    RecommendationCard(
                        recommendation: reco,
                        pipeline: model.pipeline,
                        role: model.role,
                        isExpanded: Binding(
                            get: { model.expandedID == reco.id },
                            set: { model.expandedID = $0 ? reco.id : nil }
                        ),
                        onComment: { row in
                            guard let message = row.comment else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                presentedComment = PresentedComment(stageLabel: row.label,
                                                                    message: message)
                            }
                        },
                        onNotes: {},
                        onContract: {},
                        onMore: {},
                        onValidate: { Task { await model.validateNextStage(for: reco) } }
                    )
                }
            }
        }
    }
}

// MARK: - States
//
// Loading, empty and error are built in from the start: they are most of the
// difference between a demo and something usable, and cost far more to retrofit.

struct SkeletonCard: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            RoundedRectangle(cornerRadius: 6).frame(width: 180, height: 22)
            RoundedRectangle(cornerRadius: 6).frame(width: 240, height: 16)
            RoundedRectangle(cornerRadius: 6).frame(width: 140, height: 16)
        }
        .foregroundStyle(Theme.Palette.track)
        .opacity(shimmer ? 0.55 : 1)
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct EmptyState: View {
    let filter: RecommendationFilter
    let hasQuery: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: hasQuery ? "magnifyingglass" : "tray")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(subtitle)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var title: String {
        hasQuery ? "Aucun résultat"
                 : (filter == .active ? "Aucune recommandation active"
                                      : "Aucune recommandation archivée")
    }

    private var subtitle: String {
        hasQuery ? "Essayez un autre nom."
                 : "Vos recommandations apparaîtront ici dès leur création."
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Palette.destructive)
            Text("Chargement impossible")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Réessayer", action: retry)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.brand)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
