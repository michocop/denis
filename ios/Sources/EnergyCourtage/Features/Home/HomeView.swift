import SwiftUI
import Observation

@Observable
public final class HomeViewModel {
    public private(set) var stats = DashboardStats()
    public private(set) var profile: Profile?
    public private(set) var errorMessage: String?
    public var isLoading = false

    private let profiles: ProfileRepository
    public init(profiles: ProfileRepository) { self.profiles = profiles }

    @MainActor
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let statsTask = profiles.dashboardStats()
            async let profileTask = profiles.currentProfile()
            stats = try await statsTask
            profile = try await profileTask
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct HomeView: View {
    @State private var model: HomeViewModel
    private let onNewRecommendation: () -> Void

    public init(model: HomeViewModel, onNewRecommendation: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.onNewRecommendation = onNewRecommendation
    }

    public var body: some View {
        ZStack {
            BrandBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    TrinityWordmark(logoSize: 20)

                    // the site's headline: white, then the blue gradient
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 0) {
                            Text("Bonjour, ")
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(model.profile?.firstName ?? "")
                                .brandGradient()
                        }
                        .font(Theme.Typography.screenTitle)
                        Text("Voici où en sont vos recommandations.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.top, Theme.Spacing.m)
                    .accessibilityElement(children: .combine)

                    // The mandate gate is surfaced here rather than at invoicing
                    // time: without it no invoice can be issued at all, so the
                    // apporteur should learn that before earning anything.
                    if let profile = model.profile, !profile.canBeInvoiced,
                       profile.role == .apporteur {
                        MandateNotice()
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m),
                                        GridItem(.flexible(), spacing: Theme.Spacing.m)],
                              spacing: Theme.Spacing.m) {
                        StatTile(label: "Recommandations actives",
                                 value: "\(model.stats.activeCount)",
                                 tint: Theme.Palette.brand)
                        StatTile(label: "Taux de conversion",
                                 value: String(format: "%.0f %%", model.stats.conversionRate),
                                 tint: Theme.Palette.brand)
                        StatTile(label: "En attente",
                                 value: Self.euros(model.stats.pendingTotal),
                                 tint: Theme.Palette.textSecondary)
                        StatTile(label: "Gagné",
                                 value: Self.euros(model.stats.earnedTotal),
                                 tint: Theme.Palette.successText)
                    }

                    PrimaryActionButton("Nouvelle recommandation", action: onNewRecommendation)

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .refreshable { await model.load() }
        }
        .task { await model.load() }
    }

    static func euros(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: amount as NSDecimalNumber) ?? "—"
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(value)
                .font(Theme.Typography.display(28, .semibold, relativeTo: .title))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(Theme.Spacing.l)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }
}

/// Self-billing needs a prior mandate, so this blocks payment, not just a form.
struct MandateNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.Palette.rewardText)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mandat de facturation à signer")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Tant qu'il n'est pas signé, aucune facture ne peut être émise en votre nom et vos gains ne peuvent pas être réglés.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Palette.rewardSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.Palette.rewardText.opacity(0.25), lineWidth: 1)
        )
    }
}
