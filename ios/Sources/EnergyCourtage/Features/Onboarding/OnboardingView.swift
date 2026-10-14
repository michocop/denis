import SwiftUI
import QuickLook
import Observation
import CryptoKit

/// The apporteur's first minutes: how they work, who they are for the
/// invoices, then the contract and its annex, signed with one code by SMS.
/// Nothing in the app is reachable before it is done -- the contract is what
/// makes someone an apporteur -- and it is never shown again afterwards.
@Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Comparable {
        case status, details, contract, done
        public static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public private(set) var step: Step = .status
    public var status: BusinessStatus?
    public var draft: Profile?
    public private(set) var contract: LegalDocument?
    public private(set) var mandate: LegalDocument?
    public var hasReadToEnd = false
    public var agrees = false
    public var signingStep: SigningStep?
    public private(set) var signed: ApporteurContract?
    public private(set) var errorMessage: String?
    public private(set) var isWorking = false
    /// The PDF once fetched, for Quick Look.
    public var previewURL: URL?
    public private(set) var isPreparingPDF = false
    /// Answered with a vibration each time a step is passed, and once, more
    /// strongly, at the signature.
    public private(set) var advances = 0
    public private(set) var signatures = 0

    let profiles: ProfileRepository
    let legal: LegalRepository
    let sms: SmsRepository
    let contracts: ContractRepository

    public init(profiles: ProfileRepository, legal: LegalRepository,
                sms: SmsRepository, contracts: ContractRepository) {
        self.profiles = profiles; self.legal = legal; self.sms = sms; self.contracts = contracts
    }

    public var firstName: String { draft?.firstName ?? "" }

    @MainActor
    public func load() async {
        do {
            let profile = try await profiles.currentProfile()
            if draft == nil {
                draft = profile
                status = profile.businessStatus
            }
            let documents = try await legal.documents()
            contract = documents.first { $0.key == "contrat_apporteur" }
            mandate = documents.first { $0.key == "mandat_facturation" }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Steps

    @MainActor
    public func choose(_ status: BusinessStatus) {
        let changed = self.status != status
        self.status = status
        // a form that belongs to the other status would read wrong
        if changed, var draft, !status.legalForms.contains(draft.legalForm ?? "") {
            draft.legalForm = status.legalForms.first
            if status == .independant { draft.companyName = nil }
            self.draft = draft
        }
    }

    @MainActor
    public func next() {
        errorMessage = nil
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
        advances += 1
    }

    @MainActor
    public func back() {
        errorMessage = nil
        guard step != .done, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// What is still missing from the details, said in one line; nil when
    /// the form can be sent.
    public var detailsProblem: String? {
        guard let draft, let status else { return "Choisissez votre statut." }
        func empty(_ s: String?) -> Bool { (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if status == .societe && empty(draft.companyName) { return "Indiquez la raison sociale." }
        if (draft.siret ?? "").filter(\.isNumber).count != 14 { return "Le SIRET compte 14 chiffres." }
        if empty(draft.address) { return "Indiquez l'adresse." }
        if (draft.postalCode ?? "").filter(\.isNumber).count != 5 { return "Le code postal compte 5 chiffres." }
        if empty(draft.city) { return "Indiquez la ville." }
        return nil
    }

    @MainActor
    public func saveDetails() async {
        guard detailsProblem == nil, var draft else { return }
        isWorking = true
        defer { isWorking = false }
        draft.siret = draft.siret?.filter(\.isNumber)
        draft.postalCode = draft.postalCode?.filter(\.isNumber)
        draft.businessStatus = status
        do {
            self.draft = try await profiles.save(draft)
            self.draft?.businessStatus = status
            if contract == nil || mandate == nil { await load() }
            next()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Signing

    /// The digest of the bytes shown: if it differs from the published one,
    /// the text changed on the way, and signing it would sign something else.
    private func digest(_ document: LegalDocument) -> String? {
        let rendered = SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined()
        return rendered == document.sha256 ? rendered : nil
    }

    @MainActor
    public func startSigning() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let status = try await sms.status()
            if !status.smsRequired { return await sign() }
            if !status.phoneVerified {
                signingStep = .enterPhone
                return
            }
            let challenge = try await sms.requestCode(.signContract, invoiceID: nil, phone: nil)
            if challenge.required {
                signingStep = .enterCode(maskedPhone: challenge.maskedPhone ?? "votre mobile")
            } else {
                await sign()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    public func requestCode(phone: String?, resend: Bool) async throws -> SmsChallenge {
        try await sms.requestCode(.signContract, invoiceID: nil, phone: phone, resend: resend)
    }

    @MainActor
    public func confirmCode(_ code: String) async throws -> SmsConfirmation {
        try await sms.confirm(.signContract, code: code, invoiceID: nil)
    }

    @MainActor
    public func codeConfirmed() async {
        signingStep = nil
        await sign()
    }

    @MainActor
    private func sign() async {
        guard let status, let contract, let mandate else {
            errorMessage = "Le contrat n'est pas disponible. Réessayez dans un instant."
            return
        }
        guard let contractDigest = digest(contract), let mandateDigest = digest(mandate) else {
            errorMessage = "Le texte affiché ne correspond pas à celui publié. Rouvrez l'application."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            signed = try await contracts.sign(status: status, contractSHA256: contractDigest,
                                              mandateSHA256: mandateDigest)
            signatures += 1
            step = .done
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - The PDF

    /// Filed by the server a few seconds after the signature: asked for until
    /// it is there, for up to half a minute.
    @MainActor
    public func openPDF() async {
        guard let signed, !isPreparingPDF else { return }
        isPreparingPDF = true
        defer { isPreparingPDF = false }
        errorMessage = nil
        for attempt in 0..<15 {
            do {
                if let data = try await contracts.pdf(of: signed) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(signed.fileName)
                    try data.write(to: url, options: .atomic)
                    previewURL = url
                    return
                }
            } catch {
                if attempt == 14 { errorMessage = error.localizedDescription; return }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        errorMessage = "Le PDF est encore en préparation. Il sera disponible dans votre profil."
    }
}

// MARK: - The screen

public struct OnboardingView: View {
    @State private var model: OnboardingModel
    private let onFinished: () -> Void
    private let onSignOut: () -> Void

    public init(model: OnboardingModel, onFinished: @escaping () -> Void,
                onSignOut: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.onFinished = onFinished
        self.onSignOut = onSignOut
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.step != .done { topBar }
            Group {
                switch model.step {
                case .status: StatusStep(model: model)
                case .details: DetailsStep(model: model)
                case .contract: ContractStep(model: model)
                case .done: DoneStep(model: model, onFinished: onFinished)
                }
            }
            .id(model.step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandBackground())
        .animation(.smooth(duration: 0.4), value: model.step)
        .task { await model.load() }
        .sheet(item: $model.signingStep) { step in
            NavigationStack { signingSheet(step) }
                .presentationDetents([.large])
        }
        .quickLookPreview($model.previewURL)
        .feedback(.selection, trigger: model.advances)
        .feedback(.success, trigger: model.signatures)
        .errorFeedback(model.errorMessage)
    }

    /// Back, the three steps as segments, and a way out.
    private var topBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button {
                model.back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .opacity(model.step == .status ? 0 : 1)
            .disabled(model.step == .status || model.isWorking)
            .accessibilityLabel("Étape précédente")

            HStack(spacing: 6) {
                ForEach([OnboardingModel.Step.status, .details, .contract], id: \.self) { step in
                    Capsule()
                        .fill(step <= model.step ? Theme.Palette.brand : Theme.Palette.track)
                        .frame(height: 4)
                }
            }
            .animation(.smooth(duration: 0.5), value: model.step)
            .accessibilityElement()
            .accessibilityLabel("Étape \(model.step.rawValue + 1) sur 3")

            Menu {
                Button("Se déconnecter", role: .destructive, action: onSignOut)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Options")
        }
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Spacing.gutter - 6)
        .padding(.top, Theme.Spacing.s)
    }

    private var demoHint: String? {
        model.sms is PreviewSmsRepository ? "Démo : le code est \(PreviewSmsRepository.demoCode)." : nil
    }

    @ViewBuilder
    private func signingSheet(_ step: SigningStep) -> some View {
        switch step {
        case .enterPhone:
            PhoneVerificationView(
                title: "Votre mobile",
                explanation: "Votre signature se confirme avec un code reçu par SMS. Ce même code valide votre numéro.",
                codeTitle: "Signer le contrat",
                codeExplanation: "Ce code confirme votre signature du contrat et de son annexe.",
                initialPhone: model.draft?.phone ?? "",
                demoHint: demoHint,
                send: { phone, resend in try await model.requestCode(phone: phone, resend: resend) },
                confirm: { try await model.confirmCode($0) },
                onConfirmed: { Task { await model.codeConfirmed() } },
                onCancel: { model.signingStep = nil })
        case .enterCode(let maskedPhone):
            ScrollView {
                SmsCodeView(
                    title: "Signer le contrat",
                    explanation: "Ce code confirme que c'est bien vous qui signez votre contrat d'apporteur d'affaires.",
                    maskedPhone: maskedPhone,
                    demoHint: demoHint,
                    resend: { try await model.requestCode(phone: nil, resend: true) },
                    confirm: { try await model.confirmCode($0) },
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
}

// MARK: - 1. Status

private struct StatusStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.firstName.isEmpty ? "Bienvenue." : "Bienvenue, \(model.firstName).")
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Comment exercez-vous ?")
                    .brandGradient()
            }
            .font(Theme.Typography.display(30, .semibold, relativeTo: .largeTitle))
            .minimumScaleFactor(0.8)
            .padding(.top, Theme.Spacing.xl)
            .staggeredAppear(index: 0)

            Text("Votre statut figure sur votre contrat et sur chacune de vos factures.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.m)
                .staggeredAppear(index: 1)

            Spacer(minLength: Theme.Spacing.l)

            VStack(spacing: Theme.Spacing.m) {
                ForEach(Array(BusinessStatus.allCases.enumerated()), id: \.element) { index, status in
                    StatusCard(status: status, isSelected: model.status == status) {
                        withAnimation(.snappy) { model.choose(status) }
                    }
                    .staggeredAppear(index: 2 + index)
                }
            }

            Spacer(minLength: Theme.Spacing.l)

            PrimaryActionButton("Continuer") { model.next() }
                .disabled(model.status == nil)
                .opacity(model.status == nil ? 0.5 : 1)
                .staggeredAppear(index: 4)
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.bottom, Theme.Spacing.m)
    }
}

private struct StatusCard: View {
    let status: BusinessStatus
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.Palette.brand : Theme.Palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(isSelected ? Theme.Palette.brandSoft : Theme.Palette.grouped))
                    .symbolEffect(.bounce, value: isSelected)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.label)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(status.explanation)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Theme.Palette.brand : Theme.Palette.hairline)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Palette.brand : .clear, lineWidth: 1.5)
            )
            .scaleEffect(isSelected ? 1.0 : 0.985)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 2. Details

private struct DetailsStep: View {
    @Bindable var model: OnboardingModel
    @FocusState private var focus: Field?

    private enum Field: Hashable { case company, siret, address, postalCode, city }

    private func binding(_ keyPath: WritableKeyPath<Profile, String?>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? "" },
                set: { model.draft?[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.status == .societe ? "Votre société" : "Votre activité")
                            .font(Theme.Typography.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("Ces informations figurent sur votre contrat et vos factures.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.top, Theme.Spacing.l)

                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        if model.status == .societe {
                            LabelledField("Raison sociale") {
                                TextField("Lefeuvre Conseil", text: binding(\.companyName))
                                    .textContentType(.organizationName)
                                    .focused($focus, equals: .company)
                                    .submitLabel(.next)
                                    .onSubmit { focus = .siret }
                            }
                        }
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text(model.status == .societe ? "Forme juridique" : "Régime")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            FormChips(options: model.status?.legalForms ?? [],
                                      selection: binding(\.legalForm))
                        }
                        LabelledField("SIRET") {
                            TextField("14 chiffres", text: binding(\.siret))
                                .keyboardType(.numberPad)
                                .focused($focus, equals: .siret)
                                .monospacedDigit()
                        }
                        LabelledField("Adresse") {
                            TextField("Numéro et rue", text: binding(\.address))
                                .textContentType(.streetAddressLine1)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .address)
                                .submitLabel(.next)
                                .onSubmit { focus = .postalCode }
                        }
                        HStack(spacing: Theme.Spacing.m) {
                            LabelledField("Code postal") {
                                TextField("59000", text: binding(\.postalCode))
                                    .keyboardType(.numberPad)
                                    .textContentType(.postalCode)
                                    .focused($focus, equals: .postalCode)
                            }
                            .frame(width: 130)
                            LabelledField("Ville") {
                                TextField("Lille", text: binding(\.city))
                                    .textContentType(.addressCity)
                                    .focused($focus, equals: .city)
                                    .submitLabel(.done)
                            }
                        }
                    }
                    .padding(Theme.Spacing.cardPadding)
                    .cardSurface()
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: Theme.Spacing.s) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryActionButton(model.isWorking ? "Enregistrement…" : "Continuer") {
                    focus = nil
                    Task { await model.saveDetails() }
                }
                .disabled(model.detailsProblem != nil || model.isWorking)
                .opacity(model.detailsProblem == nil ? 1 : 0.5)
                if let problem = model.detailsProblem, model.draft != nil {
                    Text(problem)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)
            .animation(.smooth, value: model.detailsProblem)
        }
        .onAppear {
            // the first form preselected, so a micro-entrepreneur taps nothing
            if (model.draft?.legalForm ?? "").isEmpty || !(model.status?.legalForms ?? []).contains(model.draft?.legalForm ?? "") {
                model.draft?.legalForm = model.status?.legalForms.first
            }
        }
    }
}

private struct FormChips: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        // wrapped onto as many lines as it takes: "Entreprise individuelle"
        // was cut off at the card's edge in a scrolling row
        ChipFlow(spacing: Theme.Spacing.s) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        withAnimation(.snappy) { selection = option }
                    } label: {
                        Text(option)
                            .font(Theme.Typography.label)
                            .foregroundStyle(selected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(selected ? Theme.Palette.brandSoft : Theme.Palette.grouped))
                            .overlay(Capsule().strokeBorder(selected ? Theme.Palette.brand : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
        }
    }
}

/// Lays chips out left to right, moving to the next line when one would not fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - 3. Contract

private struct ContractStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            if let contract = model.contract, let mandate = model.mandate {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Votre contrat")
                                .font(Theme.Typography.screenTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text("Lisez-le jusqu'au bout : le mandat de facturation, en annexe, permet à Trinity Énergie d'établir vos factures pour vous.")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, Theme.Spacing.l)

                        summary

                        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                            Text(contract.title)
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            LegalText(contract.body)
                            Divider().overlay(Theme.Palette.hairline)
                            Text("Annexe — \(mandate.title)")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            LegalText(mandate.body)
                            Text("Contrat version \(contract.version) · mandat version \(mandate.version)")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            // the bottom: reaching it lets the box be ticked
                            EndOfTextMarker()
                        }
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.cardPadding)
                        .cardSurface()
                    }
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.bottom, Theme.Spacing.l)
                }
                .onReadToEnd { if !model.hasReadToEnd { withAnimation(.smooth) { model.hasReadToEnd = true } } }
                footer
            } else if let message = model.errorMessage {
                Spacer()
                Text(message)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .padding(Theme.Spacing.gutter)
                SecondaryActionButton("Réessayer", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                Spacer()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }

    /// Who is signing, as what: read back before the text, so a typo in the
    /// SIRET is caught here rather than on the PDF.
    private var summary: some View {
        let draft = model.draft
        let lines: [(String, String)] = [
            ("Signataire", draft?.fullName ?? ""),
            ("Statut", [model.status?.label, draft?.legalForm].compactMap { $0 }.joined(separator: " · ")),
            model.status == .societe ? ("Société", draft?.companyName ?? "") : nil,
            ("SIRET", Self.grouped(draft?.siret ?? "")),
            ("Adresse", [draft?.address, [draft?.postalCode, draft?.city].compactMap { $0 }.joined(separator: " ")]
                .compactMap { $0 }.joined(separator: ", ")),
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(lines, id: \.0) { label, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    Text(value)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
            }
            Button("Modifier") { model.back() }
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.brand)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    static func grouped(_ siret: String) -> String {
        let d = siret.filter(\.isNumber)
        guard d.count == 14 else { return siret }
        let a = Array(d)
        return "\(String(a[0..<3])) \(String(a[3..<6])) \(String(a[6..<9])) \(String(a[9...]))"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                withAnimation(.snappy) { model.agrees.toggle() }
            } label: {
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    Image(systemName: model.agrees ? "checkmark.square.fill" : "square")
                        .font(.system(size: 22))
                        .foregroundStyle(model.agrees ? Theme.Palette.brand : Theme.Palette.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(model.hasReadToEnd
                         ? "J'ai lu et j'accepte le contrat d'apporteur d'affaires et le mandat de facturation annexé."
                         : "Faites défiler le contrat jusqu'à la fin pour pouvoir l'accepter.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.hasReadToEnd)
            .opacity(model.hasReadToEnd ? 1 : 0.6)

            PrimaryActionButton(model.isWorking ? "Un instant…" : "Signer par SMS") {
                Task { await model.startSigning() }
            }
            .disabled(!model.agrees || model.isWorking)
            .opacity(model.agrees && !model.isWorking ? 1 : 0.5)
        }
        .padding(Theme.Spacing.gutter)
        .background(Theme.Palette.surface.opacity(0.92))
        .overlay(alignment: .top) { Divider().overlay(Theme.Palette.hairline) }
        .animation(.smooth, value: model.errorMessage)
    }
}

// MARK: - 4. Done

private struct DoneStep: View {
    let model: OnboardingModel
    let onFinished: () -> Void
    @State private var sealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.l)

            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .strokeBorder(Theme.Palette.success.opacity(0.35 - Double(ring) * 0.1), lineWidth: 1.5)
                        .frame(width: 96 + CGFloat(ring) * 34, height: 96 + CGFloat(ring) * 34)
                        .scaleEffect(sealed ? 1 : 0.6)
                        .opacity(sealed ? 1 : 0)
                        .animation(.spring(response: 0.7, dampingFraction: 0.65).delay(0.15 + Double(ring) * 0.08),
                                   value: sealed)
                }
                Circle()
                    .fill(Theme.Palette.successSoft)
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Theme.Palette.success)
                    .symbolEffect(.bounce, value: sealed)
                    .scaleEffect(sealed ? 1 : 0.3)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55), value: sealed)
            }
            .frame(height: 170)

            VStack(spacing: Theme.Spacing.s) {
                Text("Contrat signé")
                    .font(Theme.Typography.display(30, .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Bienvenue dans le réseau Trinity Énergie\(model.firstName.isEmpty ? "" : ", \(model.firstName)"). Vous pouvez recommander vos premiers contacts.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Theme.Spacing.l)
            .opacity(sealed ? 1 : 0)
            .offset(y: sealed ? 0 : 12)
            .animation(.smooth(duration: 0.5).delay(0.25), value: sealed)

            if let signed = model.signed {
                VStack(spacing: Theme.Spacing.s) {
                    row("Statut", signed.businessStatus.label)
                    row("Signé le", signed.signedAt.formatted(.dateTime.day().month(.wide).year().hour().minute()))
                    row("Signature", signed.otpVerified ? "Code SMS vérifié\(signed.otpPhone.map { " · \($0)" } ?? "")" : "Depuis votre compte")
                    row("Référence", signed.reference)
                }
                .padding(Theme.Spacing.l)
                .cardSurface()
                .padding(.top, Theme.Spacing.xl)
                .opacity(sealed ? 1 : 0)
                .animation(.smooth(duration: 0.5).delay(0.4), value: sealed)
            }

            Spacer(minLength: Theme.Spacing.l)

            if let message = model.errorMessage {
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, Theme.Spacing.s)
            }
            VStack(spacing: Theme.Spacing.m) {
                SecondaryActionButton(model.isPreparingPDF ? "Préparation du PDF…" : "Voir mon contrat (PDF)",
                                      systemImage: "doc.text") {
                    Task { await model.openPDF() }
                }
                .disabled(model.isPreparingPDF)
                PrimaryActionButton("Accéder à mon espace", action: onFinished)
            }
            .opacity(sealed ? 1 : 0)
            .animation(.smooth(duration: 0.5).delay(0.55), value: sealed)
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.bottom, Theme.Spacing.m)
        .onAppear { sealed = true }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}
