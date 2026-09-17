import SwiftUI

/// The admin action sheet: filleul details plus the five powers.
///
/// Every destructive action confirms first, and "Supprimer" is a soft delete —
/// a recommendation can carry an invoice, which is legally retained, so the
/// row is never actually removed.
public struct RecommendationActionSheet: View {
    @Environment(\.dismiss) private var dismiss

    public enum Action: Hashable {
        case reassign, reminders, reset, archive, delete
    }

    private let recommendation: Recommendation
    private let onAction: (Action) -> Void

    @State private var confirming: Action?

    public init(recommendation: Recommendation, onAction: @escaping (Action) -> Void) {
        self.recommendation = recommendation
        self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            header
            details
            actions
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.gutter)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(confirmTitle, isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), titleVisibility: .visible) {
            if let action = confirming {
                Button(confirmVerb(action), role: action == .reset ? nil : .destructive) {
                    onAction(action)
                    confirming = nil
                    dismiss()
                }
            }
            Button("Annuler", role: .cancel) { confirming = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.filleulName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Recommandé par \(recommendation.parrainName)")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(RecommendationCard.relativeDate(recommendation.createdAt))
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fermer")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Informations filleul")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)

            if let phone = recommendation.filleulPhone, !phone.isEmpty,
               let dial = URL(string: "tel:" + phone.filter({ !$0.isWhitespace })) {
                Link(destination: dial) {
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: "phone").foregroundStyle(Theme.Palette.textSecondary)
                        Text(phone).foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .font(Theme.Typography.body)
                }
                .accessibilityLabel("Appeler \(recommendation.filleulName)")
            }

            detailRow(icon: "calendar",
                      text: RecommendationCard.relativeDate(recommendation.createdAt))

            // The source app prints the raw column name here when there is no
            // invoice; show the number, or say plainly that there isn't one.
            detailRow(icon: "doc.text",
                      text: recommendation.invoiceNumber.map { "Facture \($0)" }
                            ?? "Aucune facture émise")
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.textSecondary)
            Text(text).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
        }
        .font(Theme.Typography.body)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            actionRow("Réassigner", icon: "arrow.left.arrow.right") { onAction(.reassign); dismiss() }
            Divider().padding(.leading, 56)
            actionRow("Rappels", icon: "bell") { onAction(.reminders); dismiss() }
            Divider().padding(.leading, 56)
            actionRow("Remettre à zéro", icon: "arrow.counterclockwise") { confirming = .reset }
            Divider().padding(.leading, 56)
            actionRow("Archiver", icon: "archivebox") { confirming = .archive }
            Divider().padding(.leading, 56)
            actionRow("Supprimer", icon: "trash", tint: Theme.Palette.destructive) {
                confirming = .delete
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .fill(Theme.Palette.grouped)
        )
    }

    private func actionRow(_ title: String, icon: String,
                           tint: Color = Theme.Palette.textPrimary,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.l) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .frame(width: 24)
                Text(title).font(Theme.Typography.body)
                Spacer()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var confirmTitle: String {
        switch confirming {
        case .reset:   return "Remettre le suivi à zéro ?"
        case .archive: return "Archiver cette recommandation ?"
        case .delete:  return "Supprimer cette recommandation ?"
        default:       return ""
        }
    }

    private var confirmMessage: String {
        switch confirming {
        case .reset:
            return "Toutes les étapes validées seront annulées. L'historique est conservé."
        case .archive:
            return "Elle passera dans l'onglet Archivées. Une affaire perdue annule la récompense si elle n'a pas encore été facturée."
        case .delete:
            return "Elle disparaîtra des listes. Si une facture existe, elle est conservée : la loi impose de garder les factures dix ans."
        default:
            return ""
        }
    }

    private func confirmVerb(_ action: Action) -> String {
        switch action {
        case .reset:   return "Remettre à zéro"
        case .archive: return "Archiver"
        case .delete:  return "Supprimer"
        default:       return "Confirmer"
        }
    }
}
