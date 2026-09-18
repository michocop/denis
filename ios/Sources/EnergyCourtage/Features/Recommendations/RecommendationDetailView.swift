import SwiftUI

/// "Voir plus" — the full record behind a card.
public struct RecommendationDetailView: View {
    @Environment(\.dismiss) private var dismiss

    private let recommendation: Recommendation
    private let pipeline: [Stage]
    private let daysSinceActivity: Int
    private let onOpenInvoice: () -> Void
    private let onOpenNotes: () -> Void

    public init(recommendation: Recommendation, pipeline: [Stage],
                daysSinceActivity: Int,
                onOpenInvoice: @escaping () -> Void,
                onOpenNotes: @escaping () -> Void) {
        self.recommendation = recommendation
        self.pipeline = pipeline
        self.daysSinceActivity = daysSinceActivity
        self.onOpenInvoice = onOpenInvoice
        self.onOpenNotes = onOpenNotes
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if daysSinceActivity >= 7 {
                        StalenessBanner(days: daysSinceActivity)
                    }

                    section("Filleul") {
                        row("Nom", recommendation.filleulName)
                        if let phone = recommendation.filleulPhone { row("Téléphone", phone) }
                    }

                    section("Suivi") {
                        row("Recommandé par", recommendation.parrainName)
                        row("Créée le", RecommendationCard.relativeDate(recommendation.createdAt))
                        row("Étape", currentStageLabel)
                        row("Statut", statusLabel)
                    }

                    section("Récompense") {
                        row("Montant", recommendation.rewardAmount.map(Self.euros) ?? "—")
                        row("État", rewardLabel)
                        if let number = recommendation.invoiceNumber {
                            row("Facture", number)
                        }
                    }

                    SecondaryActionButton(Strings.Reco.personalNotes, systemImage: "doc",
                                          action: onOpenNotes)
                    if recommendation.invoiceNumber != nil {
                        SecondaryActionButton(Strings.Reco.viewContract, systemImage: "doc.text",
                                              action: onOpenInvoice)
                    }
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(Theme.Palette.canvas)
            .navigationTitle(recommendation.filleulName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.Actions.close) { dismiss() }
                }
            }
        }
    }

    private var currentStageLabel: String {
        pipeline.first { $0.id == recommendation.currentStageID }?.label ?? "—"
    }

    private var statusLabel: String {
        switch recommendation.status {
        case .active:       return "En cours"
        case .archivedWon:  return "Gagnée"
        case .archivedLost: return "Perdue"
        }
    }

    private var rewardLabel: String {
        switch recommendation.rewardStatus {
        case .pending:   return "En attente"
        case .earned:    return "Acquise"
        case .invoiced:  return "Facturée"
        case .paid:      return "Réglée"
        case .cancelled: return "Annulée"
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(title)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            content()
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: Theme.Spacing.l)
            Text(value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    static func euros(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "fr_FR")
        f.maximumFractionDigits = 0
        f.usesGroupingSeparator = false
        return f.string(from: amount as NSDecimalNumber) ?? "—"
    }
}

/// Nothing in the source app shows that a recommendation has gone quiet, which
/// is exactly the thing an admin needs to notice.
public struct StalenessBanner: View {
    let days: Int
    public init(days: Int) { self.days = days }

    public var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(Theme.Palette.staleText)
            Text(Strings.Reco.idleFor(days))
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.staleText)
            Spacer()
        }
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.staleSoft)
        )
    }
}

/// The private notes editor. Saved locally as you type and pushed on close, so
/// a note is never lost to a dropped connection.
public struct PersonalNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var body_ = ""
    @State private var isSaving = false

    private let initialBody: String
    private let save: (String) async throws -> Void

    public init(initialBody: String, save: @escaping (String) async throws -> Void) {
        self.initialBody = initialBody
        self.save = save
        _body_ = State(initialValue: initialBody)
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Ces notes ne sont visibles que par vous.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)

                TextEditor(text: $body_)
                    .font(Theme.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                            .fill(Theme.Palette.track)
                    )
                Spacer()
            }
            .padding(Theme.Spacing.gutter)
            .background(Theme.Palette.canvas)
            .navigationTitle(Strings.Reco.personalNotes)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Actions.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.Actions.save) {
                        Task {
                            isSaving = true
                            try? await save(body_)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || body_ == initialBody)
                }
            }
        }
    }
}
