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
    @State private var appeared = false
    private let onNewRecommendation: () -> Void
    /// Shown at the end of the header row: the notifications bell.
    private let accessory: AnyView
    private let onOpenMandate: (() -> Void)?
    private let refreshToken: Int

    public init(model: HomeViewModel, accessory: AnyView = AnyView(EmptyView()),
                onOpenMandate: (() -> Void)? = nil, refreshToken: Int = 0,
                onNewRecommendation: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.accessory = accessory
        self.onOpenMandate = onOpenMandate
        self.refreshToken = refreshToken
        self.onNewRecommendation = onNewRecommendation
    }

    public var body: some View {
        ZStack {
            BrandBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    HStack {
                        TrinityWordmark(logoSize: 20)
                        Spacer()
                        accessory
                    }
                    .padding(.top, Theme.Spacing.s)
                    .staggeredAppear(index: 0)

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
                    .staggeredAppear(index: 1, when: appeared)

                    // The mandate gate is surfaced here rather than at invoicing
                    // time: without it no invoice can be issued at all, so the
                    // apporteur should learn that before earning anything.
                    if let profile = model.profile, !profile.canBeInvoiced,
                       profile.role == .apporteur {
                        MandateNotice(onOpen: onOpenMandate)
                            .staggeredAppear(index: 2, when: appeared)
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m),
                                        GridItem(.flexible(), spacing: Theme.Spacing.m)],
                              spacing: Theme.Spacing.m) {
                        StatTile(label: "Recommandations actives",
                                 value: "\(model.stats.activeCount)",
                                 tint: Theme.Palette.brand, icon: "bolt.fill")
                            .staggeredAppear(index: 3, when: appeared)
                        StatTile(label: "Taux de conversion",
                                 value: String(format: "%.0f %%", model.stats.conversionRate),
                                 tint: Theme.Palette.brand, icon: "chart.line.uptrend.xyaxis")
                            .staggeredAppear(index: 4, when: appeared)
                        StatTile(label: "En attente",
                                 value: Self.euros(model.stats.pendingTotal),
                                 tint: Theme.Palette.ice, icon: "hourglass")
                            .staggeredAppear(index: 5, when: appeared)
                        StatTile(label: "Gagné",
                                 value: Self.euros(model.stats.earnedTotal),
                                 tint: Theme.Palette.successText, icon: "checkmark.seal.fill")
                            .staggeredAppear(index: 6, when: appeared)
                    }

                    PrimaryActionButton("Nouvelle recommandation", action: onNewRecommendation)
                        .staggeredAppear(index: 7, when: appeared)

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
        .task(id: refreshToken) {
            await model.load()
            // each part rises in on its own step of the cascade
            appeared = true
        }
    }

    static func euros(_ amount: Decimal) -> String { Money.euros(amount) }
}

/// A figure with what it counts. The label reserves two lines, so the figures
/// in a row line up whatever the labels' lengths.
struct StatTile: View {
    let label: String
    let value: String
    let tint: Color
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: Circle())
            }
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2, reservesSpace: true)
            Text(value)
                .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }
}

/// Self-billing needs a prior mandate, so this blocks payment, not just a form.
struct MandateNotice: View {
    var onOpen: (() -> Void)? = nil

    var body: some View {
        if let onOpen {
            Button(action: onOpen) { card(showsAction: true) }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Ouvre le mandat pour le lire et le signer")
        } else {
            card(showsAction: false)
        }
    }

    private func card(showsAction: Bool) -> some View {
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
                    .multilineTextAlignment(.leading)
                if showsAction {
                    Label("Lire et signer", systemImage: "signature")
                        .font(Theme.Typography.label.weight(.semibold))
                        .foregroundStyle(Theme.Palette.rewardText)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
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
