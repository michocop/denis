import SwiftUI
import Observation

@Observable
public final class InvoiceViewModel {
    public private(set) var document: InvoiceDocument?
    public private(set) var errorMessage: String?
    public var isWorking = false

    /// The PDF, once it has been fetched or produced. Held as a file URL
    /// rather than bytes because that is what the share sheet and Files want.
    public private(set) var pdfURL: URL?
    public var isPreparingPDF = false
    /// Set once a credit note has been issued against this invoice, so the
    /// screen stops offering to issue a second one.
    public private(set) var creditNoteIssued = false

    private let invoiceID: UUID
    private let repository: InvoiceRepository

    public init(invoiceID: UUID, repository: InvoiceRepository) {
        self.invoiceID = invoiceID
        self.repository = repository
    }

    /// Fetches the retained document, or produces and keeps it the first time.
    /// Written to a file named after the invoice so what lands in Files or in
    /// a mail attachment is "FA-2026-0001.pdf" and not "document.pdf".
    @MainActor
    public func preparePDF() async {
        guard let document, pdfURL == nil, !isPreparingPDF else { return }
        isPreparingPDF = true
        defer { isPreparingPDF = false }
        do {
            let data = try await repository.pdf(for: document, invoiceID: invoiceID)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(document.number).pdf")
            try data.write(to: url, options: .atomic)
            pdfURL = url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

    /// The only lawful correction to a signed invoice. It is not an edit and
    /// not a deletion: a new document in the same series carrying the negative
    /// amount, which is what keeps the numbering continuous.
    @MainActor
    public func issueCreditNote(reason: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await repository.createCreditNote(invoiceID: invoiceID, reason: reason)
            creditNoteIssued = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Set while the SMS code sheet is up: where the code went.
    public var codePrompt: SignatureCodeRequest?
    public private(set) var codeError: String?

    /// "Signer": asks the server for a code first. When SMS is not set up the
    /// answer says so and the signature goes ahead straight away.
    @MainActor
    public func sign() async {
        guard document?.documentSha256 != nil else {
            errorMessage = "Cette facture n'a pas encore de document à signer."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let request = try await repository.requestSignatureCode(invoiceID: invoiceID)
            errorMessage = nil
            if request.required {
                codeError = nil
                codePrompt = request
            } else {
                try await completeSignature()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Renvoyer le code".
    @MainActor
    public func resendCode() async {
        do {
            codePrompt = try await repository.requestSignatureCode(invoiceID: invoiceID)
            codeError = nil
        } catch {
            codeError = error.localizedDescription
        }
    }

    /// The code typed into the sheet. Only a verified code leads to signing.
    @MainActor
    public func submitCode(_ code: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let check = try await repository.verifySignatureCode(invoiceID: invoiceID, code: code)
            switch check.result {
            case .verified:
                try await completeSignature()
                codePrompt = nil
            case .wrong:
                let left = check.remaining ?? 0
                codeError = "Code incorrect. \(left) essai\(left > 1 ? "s" : "") restant\(left > 1 ? "s" : "")."
            case .expired:
                codeError = "Ce code a expiré. Demandez-en un nouveau."
            case .locked:
                codeError = "Trop d'essais. Demandez un nouveau code."
            case .none:
                codeError = "Aucun code en cours. Demandez-en un nouveau."
            }
        } catch {
            codeError = error.localizedDescription
        }
    }

    /// Signs the digest the server issued with the document. The server checks
    /// it against the invoice and refuses a mismatch, so a signature can only
    /// ever attach to the document that was served.
    @MainActor
    private func completeSignature() async throws {
        guard let digest = document?.documentSha256 else { return }
        try await repository.sign(invoiceID: invoiceID, documentSHA256: digest)
        await load()
        // The retained document shows both signatures, so it can only be
        // produced once the second one is in.
        if document?.isFullySigned == true { await preparePDF() }
    }
}

/// The facture / attestation d'apport d'affaires, with the dual-signature panel.
public struct InvoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: InvoiceViewModel
    @State private var showsCreditNote = false
    @State private var creditNoteReason = ""
    private let signerName: String
    private let isAdmin: Bool

    public init(model: InvoiceViewModel, signerName: String, isAdmin: Bool = false) {
        _model = State(wrappedValue: model)
        self.signerName = signerName
        self.isAdmin = isAdmin
    }

    public var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    if let document = model.document {
                        documentCard(document)
                        signaturePanel(document)
                        if document.isFullySigned { pdfPanel }
                        if isAdmin && document.isFullySigned { correctionPanel }
                    } else if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .padding(.vertical, 48)
                    } else {
                        ProgressView().padding(.vertical, 48)
                    }
                }
                .padding(Theme.Spacing.gutter)
            }
        }
        .task {
            await model.load()
            if model.document?.isFullySigned == true { await model.preparePDF() }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // "Vous signez": the SMS code, asked for by "Signer le document"
        .overlay {
            if let prompt = model.codePrompt, let document = model.document {
                SignatureCodeDialog(
                    documentTitle: "Reconnaissance d'honoraires",
                    amount: SignatureCodeDialog.euros(document.amount.ttc),
                    signerName: signerName,
                    sentTo: prompt.sentTo,
                    channel: prompt.channel,
                    error: model.codeError,
                    isWorking: model.isWorking,
                    onSubmit: { code in Task { await model.submitCode(code) } },
                    onResend: { Task { await model.resendCode() } },
                    onCancel: { model.codePrompt = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.codePrompt != nil)
    }

    /// Whether the person looking has already signed their side.
    private var mySideSigned: Bool {
        let role = isAdmin ? "entreprise" : "apporteur"
        return model.document?.signatures.first { $0.role == role }?.signed ?? true
    }

    /// "Fermer" and "Signer le document", pinned like in the source app.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
        // e.g. "Ajoutez un numéro de mobile…": said here, where the tap was
        if model.document != nil, let message = model.errorMessage {
            Text(message)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: Theme.Spacing.m) {
            Spacer()
            Button("Fermer") { dismiss() }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.horizontal, Theme.Spacing.l)
            if model.document != nil && !mySideSigned {
                Button {
                    Task { await model.sign() }
                } label: {
                    Text(model.isWorking ? "Envoi du code…" : "Signer le document")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                .fill(Theme.Palette.brand)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
            }
        }
        }
        .padding(Theme.Spacing.gutter)
        .background(Theme.Palette.surface)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Correcting a sealed invoice

    /// A signed invoice cannot be edited or deleted — the delete guard says so
    /// and the law requires keeping it ten years. The supported correction was
    /// documented in the runbook and implemented nowhere, which left an admin
    /// with a wrong invoice and no move.
    @ViewBuilder
    private var correctionPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("CORRECTION")
                .font(Theme.Typography.caption)
                .tracking(1.1)
                .foregroundStyle(Theme.Palette.textSecondary)

            if model.creditNoteIssued {
                Label("Avoir établi", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.success)
                Text("La commission est de nouveau due : une facture corrigée peut être établie.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Cette facture est scellée. Une erreur se corrige par un avoir — une nouvelle pièce du même registre portant le montant négatif — jamais par une modification.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Établir un avoir") { showsCreditNote = true }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.destructive)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .alert("Établir un avoir", isPresented: $showsCreditNote) {
            TextField("Motif", text: $creditNoteReason)
            Button("Annuler", role: .cancel) { creditNoteReason = "" }
            Button("Établir", role: .destructive) {
                let reason = creditNoteReason
                creditNoteReason = ""
                Task { await model.issueCreditNote(reason: reason) }
            }
            .disabled(creditNoteReason.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Le motif figure sur l'avoir et reste au registre. La facture d'origine est conservée telle quelle.")
        }
    }

    // MARK: - The retained document

    /// Once both parties have signed, the invoice exists as a file that has to
    /// be kept for ten years (art. 242 nonies A ann. II CGI) — by the company
    /// and by the apporteur, who declares it. Leaving it inside the app was
    /// leaving them no way to do that.
    @ViewBuilder
    private var pdfPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("DOCUMENT")
                .font(Theme.Typography.caption)
                .tracking(1.1)
                .foregroundStyle(Theme.Palette.textSecondary)

            if let url = model.pdfURL {
                ShareLink(item: url) {
                    Label("Enregistrer ou envoyer le PDF", systemImage: "square.and.arrow.up")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.brand)
                }
                Text("À conserver dix ans : c'est cette facture que vous déclarez.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.isPreparingPDF {
                HStack(spacing: Theme.Spacing.m) {
                    ProgressView()
                    Text("Préparation du PDF…")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else {
                Button("Réessayer") { Task { await model.preparePDF() } }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.brand)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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

            // The number stays on the page: a self-billed invoice must carry it.
            VStack(spacing: 2) {
                Text("• Reconnaissance d'honoraires")
                    .font(Theme.Typography.body.weight(.semibold))
                Text("N° \(doc.number)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Theme.Spacing.l)

            VStack(alignment: .leading, spacing: 6) {
                line("Je soussigné", doc.attestation.soussigne)
                line("Atteste avoir mis en relation", doc.attestation.misEnRelation ?? "—")
                line("Avec", doc.attestation.avec)
                line("Pour la prestation suivante", doc.attestation.prestation)
                line("Intervenue le", doc.attestation.intervenueLe)
            }

            DashedRule()
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
            DashedRule()

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

        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

}

/// The two dashed lines either side of the amount on the source document.
struct DashedRule: View {
    var body: some View {
        VStack(spacing: 2) {
            line
            line
        }
        .accessibilityHidden(true)
    }

    private var line: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(Theme.Palette.textPrimary, style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
        }
        .frame(height: 1)
    }
}
