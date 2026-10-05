import SwiftUI
import QuickLook
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
    /// Signatures that went through, counted for their vibration -- except
    /// one that follows an SMS code, whose screen has just played its own.
    public private(set) var signatures = 0

    /// Set while the apporteur proves their number or types the code.
    public var signingStep: SigningStep?
    /// The document as a PDF, shown in Quick Look before anyone signs.
    public var previewURL: URL?

    /// Renders what is about to be signed exactly as it will be filed, so the
    /// signer reads the page itself and not only the screen's summary of it.
    @MainActor
    public func previewPDF() {
        guard let document else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(document.number) (aperçu).pdf")
        do {
            try InvoicePDF.render(document).write(to: url, options: .atomic)
            previewURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
        await sign(announced: false)
    }

    /// Signs the digest the server issued with the document. The server checks
    /// it against the invoice and refuses a mismatch, so a signature can only
    /// ever attach to the document that was served.
    @MainActor
    public func sign() async {
        await sign(announced: true)
    }

    @MainActor
    private func sign(announced: Bool) async {
        guard let digest = document?.documentSha256 else {
            errorMessage = "Cette facture n'a pas encore de document à signer."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.sign(invoiceID: invoiceID, documentSHA256: digest)
            if announced { signatures += 1 }
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
                        if !document.isFullySigned {
                            SecondaryActionButton("Voir le PDF", systemImage: "doc.richtext") {
                                model.previewPDF()
                            }
                        }
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
        .quickLookPreview($model.previewURL)
        .sheet(item: $model.signingStep) { step in
            NavigationStack { signingSheet(step) }
                .presentationDetents([.large])
                .interactiveDismissDisabled(model.isWorking)
        }
        .feedback(.success, trigger: model.signatures)
        .feedback(.warning, trigger: model.creditNoteIssued) { _, issued in issued }
        .errorFeedback(model.errorMessage)
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
            hero(doc)
            partiesRow(doc)
            linesAndTotals(doc)
            attestation(doc)
            mentions(doc)
        }
    }

    private static func euros(_ amount: String, cents: Bool = true) -> String {
        Decimal(string: amount).map { Money.euros($0, cents: cents) } ?? amount
    }

    /// Where the invoice stands, said once, with its colour.
    private func status(_ doc: InvoiceDocument) -> (String, Color) {
        if doc.status == "void" { return ("Annulée", Theme.Palette.destructive) }
        if doc.isFullySigned { return (doc.status == "paid" ? "Payée" : "Signée", Theme.Palette.successText) }
        if doc.acceptsSignatures && !doc.isSigned(by: myRole) { return ("À signer", Theme.Palette.rewardText) }
        return ("En attente", Theme.Palette.ice)
    }

    /// The document's identity: kind, number, amount, dates, state.
    private func hero(_ doc: InvoiceDocument) -> some View {
        let (label, tint) = status(doc)
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.isCreditNote ? "AVOIR" : "FACTURE")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.Palette.ice)
                    Text("N° \(doc.number)")
                        .font(Theme.Typography.display(20, .semibold, relativeTo: .title3))
                        .foregroundStyle(.white)
                    if doc.isCreditNote, let original = doc.correctsNumber {
                        Text("sur la facture \(original)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.ice)
                    }
                }
                Spacer()
                Text(label)
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.25), in: Capsule())
                    .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
            }
            Text(Self.euros(doc.amount.ttc))
                .font(Theme.Typography.display(38, .semibold, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
            HStack(spacing: Theme.Spacing.xl) {
                fact("Émise le", doc.issuedOn)
                if let due = doc.dueOn { fact("Échéance", due) }
                fact("Règlement", doc.paymentMethod)
            }
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // the gradient, with the mark as a faint watermark inside it
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(colors: [Theme.Palette.brandFill, Theme.Palette.navy],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                TrinityLogo(size: 130, lineColor: .white)
                    .opacity(0.08)
                    .offset(x: 26, y: 22)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.Palette.ice.opacity(0.8))
            Text(value)
                .font(Theme.Typography.secondary.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// The supplier (the apporteur, in whose name it is issued) and the client.
    private func partiesRow(_ doc: InvoiceDocument) -> some View {
        let a = doc.apporteur
        let supplier = [a.company, a.address,
                        [a.postalCode, a.city].compactMap { $0 }.joined(separator: " "),
                        a.siret.map { "SIRET \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let client: (String, [String]) = doc.customer.map { c in
            (c.legalName, [c.address, "\(c.postalCode) \(c.city)", "SIREN \(c.siren)"])
        } ?? (doc.issuer.company ?? doc.issuer.name, [doc.issuer.city].compactMap { $0 })
        return HStack(alignment: .top, spacing: Theme.Spacing.m) {
            partyCard("FOURNISSEUR", a.name, supplier)
            partyCard("CLIENT", client.0, client.1)
        }
    }

    private func partyCard(_ label: String, _ name: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.Palette.brand)
            Text(name)
                .font(Theme.Typography.label.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(radius: 18)
    }

    /// What is invoiced, then HT / TVA / TTC.
    private func linesAndTotals(_ doc: InvoiceDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.attestation.prestation)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Mise en relation avec \(doc.attestation.avec), le \(doc.attestation.intervenueLe)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: Theme.Spacing.m)
                Text(Self.euros(doc.amount.ht))
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Divider().overlay(Theme.Palette.hairline)
            total("Total HT", Self.euros(doc.amount.ht))
            total("TVA (\(doc.amount.vatRate as NSDecimalNumber) %)", Self.euros(doc.amount.vat))
            HStack {
                Text(doc.isCreditNote ? "Total TTC à déduire" : "Total TTC")
                    .font(Theme.Typography.body.weight(.semibold))
                Spacer()
                Text(Self.euros(doc.amount.ttc))
                    .font(Theme.Typography.amount)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .background(Theme.Palette.navy, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.Palette.brand.opacity(0.4), lineWidth: 1))
        }
        .padding(Theme.Spacing.cardPadding)
        .cardSurface()
    }

    private func total(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.Palette.textPrimary)
        }
        .font(Theme.Typography.secondary)
    }

    /// The apporteur's attestation, as what it is: their statement.
    @ViewBuilder
    private func attestation(_ doc: InvoiceDocument) -> some View {
        if !doc.isCreditNote {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Capsule().fill(Theme.Palette.brand).frame(width: 3)
                Text("Je soussigné(e) \(doc.attestation.soussigne) atteste avoir mis en relation "
                     + "\(doc.attestation.misEnRelation ?? "la société") avec \(doc.attestation.avec) "
                     + "pour la prestation ci-dessus.")
                    .font(Theme.Typography.secondary)
                    .italic()
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.s)
        }
    }

    /// Every mandatory mention, folded: they are on the document, and on the
    /// PDF, but do not need to fill the screen.
    private func mentions(_ doc: InvoiceDocument) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach([doc.selfBillingMention, doc.legalMentions, doc.latePaymentMention,
                         "Fait à \(doc.place), le \(doc.issuedOn).", doc.taxNotice]
                    .compactMap { $0 }, id: \.self) { text in
                    Text(text)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Theme.Spacing.s)
        } label: {
            Label("Mentions légales", systemImage: "text.book.closed")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .tint(Theme.Palette.textSecondary)
        .padding(Theme.Spacing.l)
        .cardSurface(radius: 18)
    }

    private static let signedAt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM yyyy 'à' HH:mm"
        return f
    }()

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
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    Image(systemName: signature.signed ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(signature.signed ? Theme.Palette.success
                                                          : Theme.Palette.pendingRing)
                        .symbolEffect(.bounce, value: signature.signed)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Theme.Spacing.s) {
                            Text(signature.role == "apporteur" ? "L'apporteur" : "L'entreprise")
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            if !signature.signed {
                                Text("En attente")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.rewardText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.Palette.rewardSoft, in: Capsule())
                            }
                        }
                        Text(signature.name)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        if signature.signed {
                            if let at = signature.signedAt {
                                Text("Signé le \(Self.signedAt.string(from: at))")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            if signature.smsVerified == true {
                                Label("Confirmé par SMS\(signature.smsPhone.map { " · \($0)" } ?? "")",
                                      systemImage: "checkmark.shield.fill")
                                    .font(Theme.Typography.caption.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.successText)
                            }
                        }
                    }
                    Spacer(minLength: 0)
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
