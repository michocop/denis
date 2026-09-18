import SwiftUI

/// The create-recommendation form.
///
/// The consent checkbox is a legal requirement, not a courtesy: the filleul
/// never signed up to anything, so storing their name and phone number needs a
/// lawful basis, and the apporteur confirming they informed them is it. The
/// database records the confirmation timestamp on every row.
public struct CreateRecommendationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft = RecommendationDraft()
    @State private var offers: [Offer] = []
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var duplicate = DuplicateCheck()
    @State private var duplicateTask: Task<Void, Never>?

    private let recommendations: RecommendationsRepository
    private let catalogue: CatalogueRepository
    private let onCreated: (Recommendation) -> Void

    public init(recommendations: RecommendationsRepository,
                catalogue: CatalogueRepository,
                onCreated: @escaping (Recommendation) -> Void) {
        self.recommendations = recommendations
        self.catalogue = catalogue
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Qui souhaitez-vous recommander ?")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    LabelledField("Prénom") {
                        TextField("Prénom du filleul", text: $draft.firstName)
                            .textContentType(.givenName)
                    }
                    LabelledField("Nom") {
                        TextField("Nom du filleul", text: $draft.lastName)
                            .textContentType(.familyName)
                    }
                    LabelledField("Téléphone") {
                        TextField("+33 6 …", text: $draft.phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }
                    LabelledField("Email (facultatif)") {
                        TextField("adresse@exemple.fr", text: $draft.email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabelledField("Société (facultatif)") {
                        TextField("Raison sociale", text: $draft.company)
                    }

                    if !offers.isEmpty {
                        LabelledField("Prestation") {
                            Picker("Prestation", selection: $draft.offerID) {
                                Text("Non précisée").tag(UUID?.none)
                                ForEach(offers) { offer in
                                    Text(offer.title).tag(UUID?.some(offer.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Theme.Palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let warning = duplicate.warning {
                        DuplicateWarning(text: warning, blocking: duplicate.blocksSubmission)
                    }

                    consentToggle

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }

                    PrimaryActionButton(isSaving ? "Envoi…" : "Envoyer la recommandation") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSaving)
                    .opacity(canSubmit && !isSaving ? 1 : 0.5)
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(Theme.Palette.canvas)
            .navigationTitle("Nouvelle recommandation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .task {
            offers = (try? await catalogue.loadOffers()) ?? []
        }
        // Checked as they type rather than on submit: being told after filling
        // the whole form that the lead is already taken is the worst moment
        // to find out.
        .onChange(of: draft.phone) { _, _ in scheduleDuplicateCheck() }
        .onChange(of: draft.email) { _, _ in scheduleDuplicateCheck() }
        .onDisappear { duplicateTask?.cancel() }
    }

    private var consentToggle: some View {
        Toggle(isOn: $draft.consentConfirmed) {
            Text("J'ai informé cette personne que je transmets ses coordonnées et elle en est d'accord.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Theme.Palette.brand)
        .padding(Theme.Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(Theme.Palette.track)
        )
    }

    private var canSubmit: Bool { draft.isValid && !duplicate.blocksSubmission }

    /// Debounced, so a phone number typed digit by digit is one request.
    private func scheduleDuplicateCheck() {
        duplicateTask?.cancel()
        let phone = draft.phone
        let email = draft.email
        guard phone.filter(\.isNumber).count >= 9 || email.contains("@") else {
            duplicate = DuplicateCheck()
            return
        }
        duplicateTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if let result = try? await recommendations.checkDuplicate(phone: phone, email: email) {
                await MainActor.run { duplicate = result }
            }
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let created = try await recommendations.create(draft)
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


/// Amber when the lead is merely contested, red when it is already yours —
/// the second is a mistake, the first is a decision.
struct DuplicateWarning: View {
    let text: String
    let blocking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: blocking ? "exclamationmark.octagon.fill"
                                       : "exclamationmark.triangle.fill")
                .foregroundStyle(blocking ? Theme.Palette.destructive : Theme.Palette.rewardText)
            Text(text)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(blocking ? Theme.Palette.destructive.opacity(0.12)
                               : Theme.Palette.rewardSoft)
        )
        .accessibilityElement(children: .combine)
    }
}
