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

            // One screen, no scrolling: a dashboard is read at a glance, so it
            // is laid out to the height it is given -- the four tiles share
            // whatever the header, the notice and the button leave. Figures
            // are reloaded each time the tab comes back into view, which is
            // what pulling to refresh used to be for.
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Text("Voici où en sont vos recommandations.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
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

                VStack(spacing: Theme.Spacing.m) {
                    HStack(spacing: Theme.Spacing.m) {
                        StatTile(label: "Recommandations actives",
                                 value: "\(model.stats.activeCount)",
                                 tint: Theme.Palette.brand, icon: "bolt.fill", fills: true)
                            .staggeredAppear(index: 3, when: appeared)
                        StatTile(label: "Taux de conversion",
                                 value: String(format: "%.0f %%", model.stats.conversionRate),
                                 tint: Theme.Palette.brand, icon: "chart.line.uptrend.xyaxis", fills: true)
                            .staggeredAppear(index: 4, when: appeared)
                    }
                    HStack(spacing: Theme.Spacing.m) {
                        StatTile(label: "En attente",
                                 value: Self.euros(model.stats.pendingTotal),
                                 tint: Theme.Palette.ice, icon: "hourglass", fills: true)
                            .staggeredAppear(index: 5, when: appeared)
                        StatTile(label: "Gagné",
                                 value: Self.euros(model.stats.earnedTotal),
                                 tint: Theme.Palette.successText, icon: "checkmark.seal.fill", fills: true)
                            .staggeredAppear(index: 6, when: appeared)
                    }
                }
                .frame(maxHeight: .infinity)

                if let message = model.errorMessage {
                    Text(message)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.destructive)
                        .lineLimit(2)
                }

                PrimaryActionButton("Nouvelle recommandation", action: onNewRecommendation)
                    .staggeredAppear(index: 7, when: appeared)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.bottom, Theme.Spacing.l)
        }
        // Past this size the page could not hold on one screen. The rest of
        // the app follows every setting; here the figures are short enough
        // to read at this size.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
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
    /// Grows to the height it is offered, the figure settling at the bottom:
    /// Home lays its tiles out to fill the screen. Offered too little -- a
    /// small iPhone, a large text size -- the tile drops its icon first.
    var fills = false

    var body: some View {
        Group {
            if fills {
                ViewThatFits(in: .vertical) {
                    content(showsIcon: true)
                    content(showsIcon: false)
                }
            } else {
                content(showsIcon: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .padding(Theme.Spacing.l)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }

    private func content(showsIcon: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if showsIcon, let icon {
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
            if fills { Spacer(minLength: 0) }
            Text(value)
                .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
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

    /// One line and a chevron. The full consequence -- no invoice, no payment
    /// -- is spelled out in the mandate itself, one tap away; on Home it only
    /// has to be noticed, not read.
    private func card(showsAction: Bool) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "signature")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.rewardText)
                .frame(width: 34, height: 34)
                .background(Theme.Palette.rewardText.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Mandat de facturation à signer")
                    .font(Theme.Typography.label.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Requis pour recevoir vos gains.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if showsAction {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.rewardText)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
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
