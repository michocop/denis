import SwiftUI
import Observation

@Observable
public final class InvoiceViewModel {
    public private(set) var document: InvoiceDocument?
    public private(set) var errorMessage: String?
    public var isWorking = false

    private let invoiceID: UUID
    private let repository: InvoiceRepository

    public init(invoiceID: UUID, repository: InvoiceRepository) {
        self.invoiceID = invoiceID
        self.repository = repository
    }

    @MainActor
    public func load() async {
        do {
            document = try await repository.document(invoiceID: invoiceID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Signs the digest the server issued with the document. The server checks
    /// it against the invoice and refuses a mismatch, so a signature can only
    /// ever attach to the document that was served.
    @MainActor
    public func sign() async {
        guard let digest = document?.documentSha256 else {
            errorMessage = "Cette facture n'a pas encore de document à signer."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.sign(invoiceID: invoiceID, documentSHA256: digest)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The facture / attestation d'apport d'affaires, with the dual-signature panel.
public struct InvoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: InvoiceViewModel
    private let signerName: String

    public init(model: InvoiceViewModel, signerName: String) {
        _model = State(wrappedValue: model)
        self.signerName = signerName
    }

    public var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    if let document = model.document {
                        documentCard(document)
                        signaturePanel(document)
                    } else if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .padding(.vertical, 48)
                    } else {
                        ProgressView().padding(.vertical, 48)
                    }

                    HStack {
                        Spacer()
                        Button("Fermer") { dismiss() }
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .padding(Theme.Spacing.gutter)
            }
        }
        .task { await model.load() }
    }

    // MARK: - The document

    private func documentCard(_ doc: InvoiceDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.issuer.name).font(Theme.Typography.body.weight(.semibold))
                if let company = doc.issuer.company { Text(company) }
                if let city = doc.issuer.city { Text(city) }
            }
            .foregroundStyle(Theme.Palette.textPrimary)

            Text(doc.apporteur.name)
                .font(Theme.Typography.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text("• Numéro de facture \(doc.number)")
                .font(Theme.Typography.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Theme.Spacing.l)

            VStack(alignment: .leading, spacing: 6) {
                line("Je soussigné", doc.attestation.soussigne)
                line("Atteste avoir mis en relation", doc.attestation.misEnRelation ?? "—")
                line("Avec", doc.attestation.avec)
                line("Pour la prestation suivante", doc.attestation.prestation)
                line("Intervenue le", doc.attestation.intervenueLe)
            }

            Divider()
            HStack {
                Text("Montant de la prestation :")
                Spacer()
                Text("\(doc.amount.ttc) \(doc.amount.currency)")
                    .font(Theme.Typography.body.weight(.semibold))
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            if doc.amount.vatRate > 0 {
                HStack {
                    Text("dont TVA (\(doc.amount.vatRate as NSDecimalNumber) %)")
                    Spacer()
                    Text("\(doc.amount.vat) \(doc.amount.currency)")
                }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
            }
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(doc.legalMentions)
                line("Modalité de règlement", doc.paymentMethod)
                line("Fait à", doc.place)
                line("Le", doc.issuedOn)
            }

            if let notice = doc.taxNotice {
                Text(notice)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Signatures :").underline()
                ForEach(doc.signatures) { signature in
                    Text(signature.name)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func line(_ label: String, _ value: String) -> some View {
        Text("\(label) : \(value)")
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Signature panel

    private func signaturePanel(_ doc: InvoiceDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("VOUS ALLEZ SIGNER EN TANT QUE")
                .font(Theme.Typography.caption)
                .tracking(1.1)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(signerName)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            Divider()

            ForEach(doc.signatures) { signature in
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: signature.signed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(signature.signed ? Theme.Palette.success
                                                          : Theme.Palette.pendingRing)
                    Text(signature.label)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    Text(signature.signed ? "signé" : "en attente")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }

            if !doc.isFullySigned {
                PrimaryActionButton(model.isWorking ? "Signature…" : "Signer") {
                    Task { await model.sign() }
                }
                .disabled(model.isWorking)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

}
