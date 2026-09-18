import SwiftUI
import Observation

@Observable
public final class CommissionsViewModel {
    public private(set) var lines: [CommissionLine] = []
    public private(set) var errorMessage: String?
    public var year: Int = Calendar.current.component(.year, from: .now)

    private let repository: CommissionsRepository
    public init(repository: CommissionsRepository) { self.repository = repository }

    public var years: [Int] { Array(Set(lines.map(\.year))).sorted(by: >) }
    public var linesForYear: [CommissionLine] { lines.filter { $0.year == year } }

    public var earned: Decimal {
        linesForYear.reduce(0) { $0 + ($1.rewardAmount ?? 0) }
    }
    public var paid: Decimal {
        linesForYear.filter { $0.rewardStatus == .paid }
                    .reduce(0) { $0 + ($1.rewardAmount ?? 0) }
    }
    public var outstanding: Decimal { earned - paid }

    @MainActor
    public func load() async {
        do { lines = try await repository.statement(year: nil); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    /// A plain text statement the apporteur can send to their accountant.
    public func exportText(name: String) -> String {
        var out = ["Relevé d'apport d'affaires — \(name) — \(year)", ""]
        for line in linesForYear.sorted(by: { ($0.issuedOn ?? .distantPast) < ($1.issuedOn ?? .distantPast) }) {
            let amount = line.rewardAmount.map { "\($0) EUR" } ?? "—"
            out.append([line.invoiceNumber ?? "—",
                        line.filleul,
                        amount,
                        statusLabel(line.rewardStatus)].joined(separator: " | "))
        }
        out.append("")
        out.append("Total acquis : \(earned) EUR")
        out.append("Total réglé  : \(paid) EUR")
        out.append("")
        out.append("Sommes à déclarer au titre des bénéfices non commerciaux (BNC), déclaration de revenus CERFA 2042 C.")
        return out.joined(separator: "\n")
    }

    public func statusLabel(_ status: RewardStatus) -> String {
        switch status {
        case .pending:   return "En attente"
        case .earned:    return "Acquise"
        case .invoiced:  return "Facturée"
        case .paid:      return "Réglée"
        case .cancelled: return "Annulée"
        }
    }
}

/// The apporteur's own money, and the statement the app's closing message
/// tells them to produce for their tax return.
public struct CommissionsView: View {
    @State private var model: CommissionsViewModel
    private let apporteurName: String

    public init(model: CommissionsViewModel, apporteurName: String) {
        _model = State(wrappedValue: model)
        self.apporteurName = apporteurName
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if model.years.count > 1 {
                    Picker("Année", selection: $model.year) {
                        ForEach(model.years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: Theme.Spacing.m) {
                    StatTile(label: "Acquis", value: HomeView.euros(model.earned),
                             tint: Theme.Palette.successText)
                    StatTile(label: "Reste dû", value: HomeView.euros(model.outstanding),
                             tint: Theme.Palette.textPrimary)
                }

                ForEach(model.linesForYear) { line in
                    HStack(spacing: Theme.Spacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.filleul)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(line.invoiceNumber ?? "Pas encore facturée")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(line.rewardAmount.map(HomeView.euros) ?? "—")
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(model.statusLabel(line.rewardStatus))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(line.rewardStatus == .paid
                                                 ? Theme.Palette.successText
                                                 : Theme.Palette.textSecondary)
                        }
                    }
                    .padding(Theme.Spacing.l)
                    .cardSurface()
                }

                if !model.linesForYear.isEmpty {
                    ShareLink(item: model.exportText(name: apporteurName)) {
                        Label("Exporter le relevé", systemImage: "square.and.arrow.up")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.button,
                                                 style: .continuous)
                                    .stroke(Theme.Palette.hairline, lineWidth: 1)
                            )
                    }

                    Text("Ces sommes sont à déclarer au titre des bénéfices non commerciaux (BNC), via la déclaration de revenus CERFA 2042 C.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .background(Theme.Palette.canvas)
        .navigationTitle("Mes gains")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}
