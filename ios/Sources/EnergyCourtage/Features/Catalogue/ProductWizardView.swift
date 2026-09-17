import SwiftUI

/// The add-product flow. The source app shows a progress bar at roughly one
/// fifth on the first step, so five steps; the four beyond "Informations" are
/// reconstructed from what an offer row needs.
public struct ProductWizardView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case information, description, media, pricing, review

        var title: String {
            switch self {
            case .information: return "Informations sur le produit"
            case .description: return "Description"
            case .media:       return "Visuel"
            case .pricing:     return "Tarif et récompense"
            case .review:      return "Vérification"
            }
        }

        var subtitle: String {
            switch self {
            case .information: return "Saisissez les détails du produit que vous souhaitez mettre en ligne"
            case .description: return "Expliquez la prestation en quelques lignes"
            case .media:       return "Ajoutez une image représentative"
            case .pricing:     return "Définissez le mode de tarification et la récompense de l'apporteur"
            case .review:      return "Relisez avant publication"
            }
        }
    }

    @State private var step: Step = .information
    @State private var title = ""
    @State private var category = "Energie"
    @State private var description = ""
    @State private var priceMode: Offer.PriceMode = .quote
    @State private var price = ""
    @State private var reward = ""

    private let categories = ["Energie", "Télécom", "Assurance", "Autre"]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            header

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(step.title)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(step.subtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView { fields }

            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.gutter)
        .background(Theme.Palette.canvas)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.l) {
            Button {
                if let previous = Step(rawValue: step.rawValue - 1) {
                    withAnimation(.snappy) { step = previous }
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(width: 44, height: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Étape précédente")

            ProgressView(value: progress)
                .tint(Theme.Palette.brand)
                .scaleEffect(x: 1, y: 2.2, anchor: .center)
                .accessibilityLabel("Étape \(step.rawValue + 1) sur \(Step.allCases.count)")
        }
    }

    private var progress: Double {
        Double(step.rawValue + 1) / Double(Step.allCases.count)
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            switch step {
            case .information:
                LabelledField("Nom du produit") {
                    TextField("Saisissez le nom du produit", text: $title)
                }
                LabelledField("Catégorie") {
                    Picker("Catégorie", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .description:
                LabelledField("Description") {
                    TextField("Décrivez la prestation", text: $description, axis: .vertical)
                        .lineLimit(4...8)
                }

            case .media:
                RoundedRectangle(cornerRadius: Theme.Radius.image, style: .continuous)
                    .fill(Theme.Palette.track)
                    .frame(height: 200)
                    .overlay {
                        VStack(spacing: Theme.Spacing.s) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 30))
                            Text("Choisir une image").font(Theme.Typography.body)
                        }
                        .foregroundStyle(Theme.Palette.textSecondary)
                    }

            case .pricing:
                LabelledField("Mode de tarification") {
                    Picker("Mode", selection: $priceMode) {
                        Text("Sur devis").tag(Offer.PriceMode.quote)
                        Text("Prix fixe").tag(Offer.PriceMode.fixed)
                    }
                    .pickerStyle(.segmented)
                }
                if priceMode == .fixed {
                    LabelledField("Prix (€)") {
                        TextField("0", text: $price).keyboardType(.decimalPad)
                    }
                }
                LabelledField("Récompense apporteur (€)") {
                    TextField("0", text: $reward).keyboardType(.decimalPad)
                }

            case .review:
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    reviewRow("Nom", title)
                    reviewRow("Catégorie", category)
                    reviewRow("Description", description)
                    reviewRow("Tarif", priceMode == .quote ? "Sur devis" : "\(price) €")
                    reviewRow("Récompense", reward.isEmpty ? "—" : "\(reward) €")
                }
                .padding(Theme.Spacing.l)
                .cardSurface()
            }
        }
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: Theme.Spacing.l)
            Text(value.isEmpty ? "—" : value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.l) {
            Button("Annuler") { dismiss() }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity)

            Button {
                if let next = Step(rawValue: step.rawValue + 1) {
                    withAnimation(.snappy) { step = next }
                } else {
                    dismiss()
                }
            } label: {
                Text(step == .review ? "Publier" : "Suivant")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(canAdvance ? Theme.Palette.brand
                                             : Theme.Palette.brand.opacity(0.45))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canAdvance)
        }
        .overlay(alignment: .top) {
            Divider().offset(y: -Theme.Spacing.l)
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .information: return !title.trimmingCharacters(in: .whitespaces).isEmpty
        case .pricing:     return priceMode == .quote || !price.isEmpty
        default:           return true
        }
    }
}

/// Label above a bordered field — the form treatment used throughout the app.
public struct LabelledField<Content: View>: View {
    private let label: String
    private let content: Content

    public init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            content
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .stroke(Theme.Palette.hairline, lineWidth: 1)
                )
        }
    }
}
