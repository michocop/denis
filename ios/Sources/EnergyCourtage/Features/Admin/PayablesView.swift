import SwiftUI
import Observation

@Observable
public final class PayablesViewModel {
    public private(set) var invoices: [PayableInvoice] = []
    public private(set) var errorMessage: String?
    public var selection: Set<UUID> = []
    public var reference = ""
    public var isWorking = false

    private let repository: AdminRepository
    public init(repository: AdminRepository) { self.repository = repository }

    /// Grouped by apporteur, because a transfer run is organised by
    /// beneficiary, not by invoice.
    public var groups: [(apporteur: String, invoices: [PayableInvoice])] {
        Dictionary(grouping: invoices, by: \.apporteurName)
            .map { (apporteur: $0.key, invoices: $0.value.sorted { $0.issuedOn < $1.issuedOn }) }
            .sorted { $0.apporteur < $1.apporteur }
    }

    public var selectedTotal: Decimal {
        invoices.filter { selection.contains($0.invoiceId) }
                .reduce(0) { $0 + $1.amountTtc }
    }

    /// Nobody can be paid without bank details, so a selection containing one
    /// is refused here rather than failing at the bank.
    public var blockedByMissingBankDetails: [PayableInvoice] {
        invoices.filter { selection.contains($0.invoiceId) && !$0.hasBankDetails }
    }

    public var canPay: Bool {
        !selection.isEmpty && blockedByMissingBankDetails.isEmpty && !isWorking
    }

    @MainActor
    public func load() async {
        do {
            invoices = try await repository.payableInvoices()
            selection = selection.intersection(invoices.map(\.invoiceId))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    public func selectAllPayable() {
        selection = Set(invoices.filter(\.hasBankDetails).map(\.invoiceId))
    }

    @MainActor
    public func pay() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.payBatch(invoiceIDs: Array(selection),
                                          reference: reference.isEmpty ? nil : reference)
            selection = []
            reference = ""
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The payables run. Everything signed and unpaid, in one place, with a total
/// that matches the transfer file.
public struct PayablesView: View {
    @State private var model: PayablesViewModel
    @State private var confirming = false

    public init(model: PayablesViewModel) { _model = State(wrappedValue: model) }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("À régler")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    if model.invoices.isEmpty {
                        VStack(spacing: Theme.Spacing.m) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.Palette.success)
                            Text("Aucune facture en attente de règlement")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 56)
                    } else {
                        Button("Tout sélectionner") { model.selectAllPayable() }
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.brand)

                        ForEach(model.groups, id: \.apporteur) { group in
                            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                                Text(group.apporteur)
                                    .font(Theme.Typography.body.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                ForEach(group.invoices) { invoice in
                                    payableRow(invoice)
                                }
                            }
                            .padding(Theme.Spacing.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface()
                        }
                    }

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, model.selection.isEmpty ? Theme.Spacing.xl : 150)
            }
            .refreshable { await model.load() }

            if !model.selection.isEmpty { payBar }
        }
        .task { await model.load() }
        .confirmationDialog("Régler \(model.selection.count) facture(s) ?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Confirmer le règlement") { Task { await model.pay() } }
            Button(Strings.Actions.cancel, role: .cancel) {}
        } message: {
            Text("Les factures passeront au statut réglé et les apporteurs seront notifiés. Cette opération est enregistrée et ne peut pas être annulée.")
        }
    }

    private func payableRow(_ invoice: PayableInvoice) -> some View {
        Button {
            if model.selection.contains(invoice.invoiceId) {
                model.selection.remove(invoice.invoiceId)
            } else {
                model.selection.insert(invoice.invoiceId)
            }
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: model.selection.contains(invoice.invoiceId)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(model.selection.contains(invoice.invoiceId)
                                     ? Theme.Palette.brand : Theme.Palette.pendingRing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(invoice.number)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(invoice.filleul)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    if !invoice.hasBankDetails {
                        Text("Coordonnées bancaires manquantes")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                }
                Spacer()
                Text(HomeView.euros(invoice.amountTtc))
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!invoice.hasBankDetails)
        .opacity(invoice.hasBankDetails ? 1 : 0.55)
    }

    private var payBar: some View {
        VStack(spacing: Theme.Spacing.m) {
            HStack {
                Text("\(model.selection.count) sélectionnée(s)")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(HomeView.euros(model.selectedTotal))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            TextField("Référence du virement (facultatif)", text: $model.reference)
                .font(Theme.Typography.secondary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.track)
                )
            PrimaryActionButton(model.isWorking ? "Règlement…" : "Régler") {
                confirming = true
            }
            .disabled(!model.canPay)
            .opacity(model.canPay ? 1 : 0.5)
        }
        .padding(Theme.Spacing.l)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}
