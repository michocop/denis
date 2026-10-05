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
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var duplicate = DuplicateCheck()
    @State private var duplicateTask: Task<Void, Never>?
    /// The filleul's bill, attached before the lead exists and sent right
    /// after it is created: the website's "envoyez votre facture", in the app.
    @State private var attachments: [DocumentUpload] = []

    private let recommendations: RecommendationsRepository
    private let documents: DocumentsRepository?
    private let onCreated: (Recommendation) -> Void

    public init(recommendations: RecommendationsRepository,
                documents: DocumentsRepository? = nil,
                onCreated: @escaping (Recommendation) -> Void) {
        self.recommendations = recommendations
        self.documents = documents
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


                    if documents != nil { attachmentsCard }

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
            .background(BrandBackground())
            .navigationTitle("Nouvelle recommandation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        // Checked as they type rather than on submit: being told after filling
        // the whole form that the lead is already taken is the worst moment
        // to find out.
        .onChange(of: draft.phone) { _, _ in scheduleDuplicateCheck() }
        .onChange(of: draft.email) { _, _ in scheduleDuplicateCheck() }
        .errorFeedback(errorMessage)
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
            // The lead exists whatever happens to the files; one that fails
            // to send can be added again from the lead's page.
            var failed: [String] = []
            if let documents {
                for upload in attachments {
                    do { _ = try await documents.add(upload, to: created.id) }
                    catch { failed.append(upload.filename) }
                }
            }
            onCreated(created)
            if failed.isEmpty {
                dismiss()
            } else {
                attachments = []
                errorMessage = "Recommandation envoyée, mais ces documents n'ont pas pu l'être : "
                    + failed.joined(separator: ", ") + ". Ajoutez-les depuis la recommandation."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var attachmentsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Facture d'énergie du filleul")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Facultatif, mais c'est elle qui permet de lui proposer une meilleure offre.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(attachments.enumerated()), id: \.offset) { index, upload in
                HStack {
                    Image(systemName: upload.mimeType == "application/pdf" ? "doc.richtext" : "photo")
                        .foregroundStyle(Theme.Palette.brand)
                    Text(upload.filename)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        attachments.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer \(upload.filename)")
                }
            }

            AddDocumentButton(title: attachments.isEmpty ? "Joindre la facture" : "Ajouter un document",
                              onPicked: { picked in
                                  let tooLarge = picked.filter { $0.data.count > DocumentUpload.maxBytes }
                                  attachments += picked.filter { $0.data.count <= DocumentUpload.maxBytes }
                                  if !tooLarge.isEmpty { errorMessage = DocumentError.tooLarge.localizedDescription }
                              },
                              onError: { errorMessage = $0 })
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
