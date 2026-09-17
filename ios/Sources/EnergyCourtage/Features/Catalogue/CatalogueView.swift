import SwiftUI
import Observation

@Observable
public final class CatalogueViewModel {
    public private(set) var offers: [Offer] = []
    public private(set) var errorMessage: String?
    public var isLoading = false
    public var query = ""
    public var category: String? = nil

    public let role: UserRole
    private let repository: CatalogueRepository

    public init(repository: CatalogueRepository, role: UserRole) {
        self.repository = repository
        self.role = role
    }

    public var categories: [String] {
        Array(Set(offers.map(\.category))).sorted()
    }

    public var visibleOffers: [Offer] {
        offers.filter { offer in
            (category == nil || offer.category == category)
            && (query.isEmpty || offer.title.localizedCaseInsensitiveContains(query)
                || (offer.description ?? "").localizedCaseInsensitiveContains(query))
        }
    }

    @MainActor
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            offers = try await repository.loadOffers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    public func delete(_ offer: Offer) async {
        do {
            try await repository.delete(offerID: offer.id)
            offers.removeAll { $0.id == offer.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct CatalogueView: View {
    @State private var model: CatalogueViewModel
    @State private var pendingDeletion: Offer?
    @State private var showsWizard = false

    public init(model: CatalogueViewModel) {
        _model = State(wrappedValue: model)
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Catalogue")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    SearchField("Rechercher un produit...", text: $model.query)

                    categoryChips

                    ForEach(model.visibleOffers) { offer in
                        ProductCard(
                            offer: offer,
                            showsAdminActions: model.role.isAdmin,
                            onEdit: { showsWizard = true },
                            onDelete: { pendingDeletion = offer }
                        )
                    }

                    if model.visibleOffers.isEmpty && !model.isLoading {
                        EmptyCatalogueState(hasQuery: !model.query.isEmpty)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                // The source app's floating button covers the last card's price;
                // this inset keeps the content clear of it.
                .padding(.bottom, 96)
            }
            .refreshable { await model.load() }

            if model.role.isAdmin {
                Button { showsWizard = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Theme.Palette.brand))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.xl)
                .accessibilityLabel("Ajouter un produit")
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showsWizard) { ProductWizardView() }
        .confirmationDialog(
            "Retirer ce produit du catalogue ?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Retirer", role: .destructive) {
                if let offer = pendingDeletion {
                    Task { await model.delete(offer) }
                }
                pendingDeletion = nil
            }
            Button("Annuler", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Le produit sera dépublié. Les recommandations qui s'y rapportent le conservent dans leur historique.")
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.m) {
                CategoryChip(title: "Tous", isSelected: model.category == nil) {
                    model.category = nil
                }
                ForEach(model.categories, id: \.self) { category in
                    CategoryChip(title: category, isSelected: model.category == category) {
                        model.category = category
                    }
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

/// Outlined pill; selected takes a blue border, blue label and a pale fill.
public struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title; self.isSelected = isSelected; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(isSelected ? Theme.Palette.brand : Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .fill(isSelected ? Theme.Palette.brandSoft : Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .stroke(isSelected ? Theme.Palette.brand : Theme.Palette.hairline,
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

public struct ProductCard: View {
    let offer: Offer
    let showsAdminActions: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    public init(offer: Offer, showsAdminActions: Bool,
                onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.offer = offer; self.showsAdminActions = showsAdminActions
        self.onEdit = onEdit; self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            media

            HStack(alignment: .firstTextBaseline) {
                Text(offer.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: Theme.Spacing.s)
                Text(offer.availabilityLabel)
                    .font(Theme.Typography.badge)
                    .foregroundStyle(Theme.Palette.successText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.Palette.successSoft))
            }

            if let description = offer.description {
                Text(description)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Label(offer.category, systemImage: "tag")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(offer.priceLabel)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.Palette.brand)
            }
        }
        .padding(Theme.Spacing.l)
        .cardSurface()
    }

    private var media: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.image, style: .continuous)
            .fill(Theme.Palette.track)
            .aspectRatio(16.0/10.0, contentMode: .fit)
            .overlay {
                // Placeholder until real artwork exists: the source app reuses
                // one stock photo for every product, which is not worth cloning.
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .overlay(alignment: .topTrailing) {
                if showsAdminActions {
                    HStack(spacing: Theme.Spacing.s) {
                        iconButton("pencil", tint: Theme.Palette.textPrimary,
                                   label: "Modifier \(offer.title)", action: onEdit)
                        iconButton("trash", tint: Theme.Palette.destructive,
                                   label: "Retirer \(offer.title)", action: onDelete)
                    }
                    .padding(Theme.Spacing.m)
                }
            }
    }

    private func iconButton(_ systemName: String, tint: Color,
                            label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct EmptyCatalogueState: View {
    let hasQuery: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: hasQuery ? "magnifyingglass" : "book")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(hasQuery ? "Aucun produit trouvé" : "Le catalogue est vide")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}
