import SwiftUI

/// The `Recommandations` tab.
public struct RecommendationsView: View {

    @State private var model: RecommendationsViewModel
    @State private var presentedComment: PresentedComment?
    @State private var sheet: Sheet?
    @State private var admins: [Profile] = []

    private let dependencies: Dependencies
    private let signerName: String

    private struct PresentedComment: Identifiable {
        let id = UUID()
        let stageLabel: String
        let message: String
    }

    /// One enum for every sheet this screen can raise: two `.sheet` modifiers
    /// on the same view silently fight, and an identified item makes the
    /// presented value and its data arrive together.
    private enum Sheet: Identifiable {
        case notes(Recommendation, String)
        case invoice(UUID)
        case detail(Recommendation)
        case actions(Recommendation)
        case reminders(Recommendation)

        var id: String {
            switch self {
            case .notes(let r, _):   return "notes-\(r.id)"
            case .invoice(let id):   return "invoice-\(id)"
            case .detail(let r):     return "detail-\(r.id)"
            case .actions(let r):    return "actions-\(r.id)"
            case .reminders(let r):  return "reminders-\(r.id)"
            }
        }
    }

    public init(model: RecommendationsViewModel, dependencies: Dependencies,
                signerName: String) {
        _model = State(wrappedValue: model)
        self.dependencies = dependencies
        self.signerName = signerName
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
        .sheet(item: $sheet) { presented in
            switch presented {
            case .notes(let reco, let body):
                PersonalNotesView(initialBody: body) { text in
                    try await dependencies.recommendations.saveNote(
                        recommendationID: reco.id, body: text
                    )
                    await model.load()
                }

            case .invoice(let invoiceID):
                InvoiceView(
                    model: InvoiceViewModel(invoiceID: invoiceID,
                                            repository: dependencies.invoices),
                    signerName: signerName,
                    isAdmin: model.role.isAdmin
                )

            case .detail(let reco):
                RecommendationDetailView(
                    recommendation: reco,
                    pipeline: model.pipeline,
                    daysSinceActivity: reco.daysSinceActivity,
                    admins: model.role.isAdmin ? admins : [],
                    onOpenInvoice: {
                        if let invoiceID = reco.invoiceID { sheet = .invoice(invoiceID) }
                    },
                    onOpenNotes: { Task { await openNotes(reco) } },
                    onReassign: model.role.isAdmin ? { adminID in
                        do {
                            try await dependencies.recommendations.reassign(
                                recommendationID: reco.id, to: adminID)
                            await model.load()
                            sheet = nil
                        } catch { await model.report(error) }
                    } : nil,
                    onSetAmount: model.role.isAdmin ? { amount in
                        do {
                            try await dependencies.recommendations.setRewardAmount(
                                recommendationID: reco.id, amount: amount)
                            await model.load()
                            sheet = nil
                        } catch { await model.report(error) }
                    } : nil
                )

            case .actions(let reco):
                RecommendationActionSheet(recommendation: reco) { action in
                    Task { await perform(action, on: reco) }
                }

            case .reminders(let reco):
                RemindersView(recommendationID: reco.id,
                              filleulName: reco.filleulName,
                              repository: dependencies.reminders)
            }
        }
        .animation(.snappy(duration: 0.25), value: model.hasStaleData)
        .task {
            await model.load()
            model.startWatching()
            // Needed before "Réassigner" can offer anyone. Loaded once here
            // rather than each time the sheet opens, because the list of
            // administrators changes about never.
            if model.role.isAdmin {
                admins = (try? await dependencies.recommendations.loadAdmins()) ?? []
            }
        }
        .onChange(of: model.filter) { _, _ in Task { await model.load() } }
        .onChange(of: model.query) { _, _ in model.searchChanged() }
    }

    private func openNotes(_ reco: Recommendation) async {
        let body = (try? await dependencies.recommendations.note(recommendationID: reco.id)) ?? ""
        sheet = .notes(reco, body)
    }

    private func perform(_ action: RecommendationActionSheet.Action,
                         on reco: Recommendation) async {
        let repository = dependencies.recommendations
        do {
            switch action {
            case .reassign:
                // Reassignment needs a person picked, which the sheet cannot
                // do on its own; the detail screen owns that choice.
                sheet = .detail(reco)
                return
            case .reminders:
                sheet = .reminders(reco)
                return
            case .reset:
                try await repository.resetPipeline(recommendationID: reco.id)
            case .archiveWon:
                try await repository.archive(recommendationID: reco.id, won: true)
            case .archiveLost:
                try await repository.archive(recommendationID: reco.id, won: false)
            case .delete:
                try await repository.softDelete(recommendationID: reco.id)
            case .issueInvoice:
                // Straight into the invoice: it needs both signatures before
                // anyone is paid, and the admin's is one of them.
                let invoiceID = try await dependencies.invoices.issue(recommendationID: reco.id)
                await model.load()
                sheet = .invoice(invoiceID)
                return
            }
            await model.load()
        } catch {
            await model.report(error)
        }
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
                        onNotes: { Task { await openNotes(reco) } },
                        onContract: {
                            if let invoiceID = reco.invoiceID { sheet = .invoice(invoiceID) }
                        },
                        onMore: { sheet = .detail(reco) },
                        onValidate: { Task { await model.validateNextStage(for: reco) } }
                    )
                    // The action sheet is admin-only, and reached by pressing
                    // the card rather than by a control that would clutter it
                    // for the apporteur, who has none of these powers.
                    .contextMenu {
                        if model.role.isAdmin {
                            Button("Gérer la recommandation", systemImage: "slider.horizontal.3") {
                                sheet = .actions(reco)
                            }
                        }
                    }
                    .task { await model.loadNextPageIfNeeded(currentItem: reco) }
                }

                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.l)
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
