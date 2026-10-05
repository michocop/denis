import SwiftUI
import Observation

/// Where an apporteur's signature stands between "Signer" and the signature:
/// a number to give first (its code then proves it and signs, one SMS), or a
/// code on its way to the number already proven.
public enum SigningStep: Identifiable, Equatable {
    case enterPhone
    case enterCode(maskedPhone: String)

    public var id: String {
        switch self {
        case .enterPhone: "phone"
        case .enterCode: "code"
        }
    }
}

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

    /// Set while the apporteur proves their number or types the code.
    public var signingStep: SigningStep?

    private let invoiceID: UUID
    private let repository: InvoiceRepository
    public let sms: SmsRepository

    public init(invoiceID: UUID, repository: InvoiceRepository,
                sms: SmsRepository = PreviewSmsRepository()) {
        self.invoiceID = invoiceID
        self.repository = repository
        self.sms = sms
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

    /// "Signer", confirmed. The company signs from an admin's own session; the
    /// apporteur's signature -- the one self-billing rests on -- also takes a
    /// code sent by SMS to their verified mobile, once the company has SMS set
    /// up. The server enforces this; here it only decides what comes next.
    @MainActor
    public func startSigning(asCompany: Bool) async {
        errorMessage = nil
        guard !asCompany else { return await sign() }
        isWorking = true
        defer { isWorking = false }
        do {
            let status = try await sms.status()
            if !status.smsRequired {
                isWorking = false
                return await sign()
            }
            if !status.phoneVerified {
                signingStep = .enterPhone
                return
            }
            try await sendSigningCode()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends the signing code to the proven number. No SMS goes out when the
    /// server needs none: SMS not set up, or a code confirmed in the last ten
    /// minutes still covers this signature -- which then goes ahead.
    @MainActor
    public func sendSigningCode() async throws {
        let challenge = try await sms.requestCode(.signInvoice, invoiceID: invoiceID, phone: nil)
        if challenge.required {
            signingStep = .enterCode(maskedPhone: challenge.maskedPhone ?? "votre mobile")
        } else {
            signingStep = nil
            isWorking = false
            await sign()
        }
    }

    /// From the number step: the code goes to the number typed, and coming
    /// back proves it as well as confirming the signature.
    @MainActor
    public func requestSigningCode(phone: String?, resend: Bool) async throws -> SmsChallenge {
        try await sms.requestCode(.signInvoice, invoiceID: invoiceID, phone: phone, resend: resend)
    }

    @MainActor
    public func resendSigningCode() async throws -> SmsChallenge {
        try await sms.requestCode(.signInvoice, invoiceID: invoiceID, phone: nil, resend: true)
    }

    @MainActor
    public func confirmSigningCode(_ code: String) async throws -> SmsConfirmation {
        try await sms.confirm(.signInvoice, code: code, invoiceID: invoiceID)
    }

    /// The code was right: the server holds it for this invoice, and the
    /// signature uses it up.
    @MainActor
    public func codeConfirmed() async {
        signingStep = nil
        await sign()
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
            // The retained document shows both signatures, so it can only be
            // produced once the second one is in.
            if document?.isFullySigned == true { await preparePDF() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The facture / attestation d'apport d'affaires, with the dual-signature panel.
public struct InvoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: InvoiceViewModel
    @State private var showsCreditNote = false
    @State private var creditNoteReason = ""
    @State private var confirmsSigning = false
    private let signerName: String
    private let isAdmin: Bool

    public init(model: InvoiceViewModel, signerName: String, isAdmin: Bool = false) {
        _model = State(wrappedValue: model)
        self.signerName = signerName
        self.isAdmin = isAdmin
    }

    public var body: some View {
        ZStack {
            BrandBackground()

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
        .task {
            await model.load()
            if model.document?.isFullySigned == true { await model.preparePDF() }
        }
        .sheet(item: $model.signingStep) { step in
            NavigationStack { signingSheet(step) }
                .presentationDetents([.large])
                .interactiveDismissDisabled(model.isWorking)
        }
    }

    // MARK: - The code by SMS

    private var demoHint: String? {
        model.sms is PreviewSmsRepository ? "Démo : le code est \(PreviewSmsRepository.demoCode)." : nil
    }

    @ViewBuilder
    private func signingSheet(_ step: SigningStep) -> some View {
        switch step {
        case .enterPhone:
            PhoneVerificationView(
                title: "Votre mobile",
                explanation: "Votre signature se confirme avec un code reçu par SMS. Ce même code validera votre numéro : un seul SMS.",
                codeTitle: "Signer la facture",
                codeExplanation: "Ce code confirme votre signature et votre numéro.",
                demoHint: demoHint,
                send: { phone, resend in try await model.requestSigningCode(phone: phone, resend: resend) },
                confirm: { try await model.confirmSigningCode($0) },
                onConfirmed: { Task { await model.codeConfirmed() } },
                onCancel: { model.signingStep = nil })
        case .enterCode(let maskedPhone):
            ScrollView {
                SmsCodeView(
                    title: "Signer la facture",
                    explanation: "Ce code confirme que c'est bien vous qui signez \(model.document?.number ?? "cette facture"). Il reste valable 10 minutes pour vos autres signatures.",
                    maskedPhone: maskedPhone,
                    demoHint: demoHint,
                    resend: { try await model.resendSigningCode() },
                    confirm: { try await model.confirmSigningCode($0) },
                    onConfirmed: { Task { await model.codeConfirmed() } })
                .padding(Theme.Spacing.gutter)
            }
            .background(BrandBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { model.signingStep = nil }
                }
            }
        }
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
            // The customer is the company by its legal identity; the admin's
            // own name is only shown on invoices issued before that was kept.
            VStack(alignment: .leading, spacing: 2) {
                if let customer = doc.customer {
                    Text(customer.legalName).font(Theme.Typography.body.weight(.semibold))
                    Text(customer.address)
                    Text("\(customer.postalCode) \(customer.city)")
                    Text("SIREN \(customer.siren)")
                } else {
                    Text(doc.issuer.name).font(Theme.Typography.body.weight(.semibold))
                    if let company = doc.issuer.company { Text(company) }
                    if let city = doc.issuer.city { Text(city) }
                }
            }
            .foregroundStyle(Theme.Palette.textPrimary)

            Text(doc.apporteur.name)
                .font(Theme.Typography.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(spacing: 4) {
                Text(doc.isCreditNote ? "• Avoir \(doc.number)" : "• Numéro de facture \(doc.number)")
                    .font(Theme.Typography.body.weight(.semibold))
                if doc.isCreditNote, let original = doc.correctsNumber {
                    Text("sur la facture \(original)")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
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
                if let due = doc.dueOn { line("Échéance", due) }
            }

            if let selfBilling = doc.selfBillingMention {
                Text(selfBilling)
                    .font(Theme.Typography.secondary.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let late = doc.latePaymentMention {
                Text(late)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The side this reader signs for. The server derives it the same way
    /// (`sign_invoice` looks at who is calling), so this only decides what the
    /// panel offers.
    private var myRole: String { isAdmin ? "entreprise" : "apporteur" }
    private var otherPartyLabel: String { isAdmin ? "de l'apporteur" : "de l'entreprise" }

    private func signaturePanel(_ doc: InvoiceDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if doc.acceptsSignatures && !doc.isSigned(by: myRole) {
                Text("VOUS ALLEZ SIGNER EN TANT QUE")
                    .font(Theme.Typography.caption)
                    .tracking(1.1)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(signerName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Divider()
            }

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
                    if signature.signed, signature.smsVerified == true {
                        Label("signé · SMS", systemImage: "checkmark.shield")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .accessibilityLabel("signé, confirmé par SMS")
                    } else {
                        Text(signature.signed ? "signé" : "en attente")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if doc.status == "void" {
                Text("Cette facture a été annulée et ne peut plus être signée.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else if doc.acceptsSignatures && !doc.isSigned(by: myRole) {
                // One tap used to sign, with nothing between the finger and a
                // legally binding signature. It asks first now.
                PrimaryActionButton(model.isWorking ? "Signature…" : "Signer") {
                    confirmsSigning = true
                }
                .disabled(model.isWorking)
                if let message = model.errorMessage {
                    Text(message)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !doc.isFullySigned {
                // The button stayed on screen after signing, and tapping it
                // again only produced an error from the server.
                Text("Vous avez signé. En attente de la signature \(otherPartyLabel).")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .confirmationDialog("Signer la facture \(doc.number) ?",
                            isPresented: $confirmsSigning, titleVisibility: .visible) {
            Button("Signer") { Task { await model.startSigning(asCompany: isAdmin) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Votre signature électronique vaut accord sur ce document, pour un montant de \(doc.amount.ttc) \(doc.amount.currency) TTC. Elle ne pourra pas être retirée.")
        }
    }

}
