import SwiftUI

/// Who the apporteur is on their invoices.
///
/// Every invoice the company draws up in an apporteur's name prints them as
/// the supplier: name, company, legal form, address, SIRET. None of it could
/// be entered from the app -- `ProfileRepository.save` existed and no screen
/// called it -- so those lines came out blank. What is saved here is copied
/// onto each invoice when it is issued; invoices already issued keep what they
/// said.
public struct BillingDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Profile
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let save: (Profile) async throws -> Void

    public init(profile: Profile, save: @escaping (Profile) async throws -> Void) {
        _draft = State(initialValue: profile)
        self.save = save
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Ces informations figurent sur les factures établies en votre nom. Les factures déjà émises ne sont pas modifiées.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabelledField("Raison sociale (facultatif)") {
                        TextField("Nom de votre entreprise", text: binding(\.companyName))
                            .textContentType(.organizationName)
                    }
                    LabelledField("Statut (facultatif)") {
                        TextField("Micro-entreprise, SASU, particulier…", text: binding(\.legalForm))
                    }
                    LabelledField("SIRET (facultatif)") {
                        TextField("14 chiffres", text: binding(\.siret))
                            .keyboardType(.numberPad)
                    }
                    LabelledField("Adresse") {
                        TextField("Numéro et rue", text: binding(\.address))
                            .textContentType(.streetAddressLine1)
                    }
                    HStack(spacing: Theme.Spacing.m) {
                        LabelledField("Code postal") {
                            TextField("59000", text: binding(\.postalCode))
                                .keyboardType(.numberPad)
                                .textContentType(.postalCode)
                        }
                        .frame(maxWidth: 130)
                        LabelledField("Ville") {
                            TextField("Ville", text: binding(\.city))
                                .textContentType(.addressCity)
                        }
                    }
                    LabelledField("Téléphone") {
                        TextField("06 12 34 56 78", text: binding(\.phone))
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }

                    if let problem = validationProblem ?? errorMessage {
                        Text(problem)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryActionButton(isSaving ? "Enregistrement…" : "Enregistrer") {
                        Task { await submit() }
                    }
                    .disabled(isSaving || validationProblem != nil)
                    .opacity(isSaving || validationProblem != nil ? 0.5 : 1)
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(BrandBackground())
            .navigationTitle("Informations de facturation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    /// Checked here so a typo is caught while the person is still looking at
    /// it, rather than printed on an invoice that is then kept ten years.
    private var validationProblem: String? {
        let siret = (draft.siret ?? "").filter { !$0.isWhitespace }
        if !siret.isEmpty && (siret.count != 14 || !siret.allSatisfy(\.isNumber)) {
            return "Le SIRET compte 14 chiffres."
        }
        let postalCode = (draft.postalCode ?? "").trimmingCharacters(in: .whitespaces)
        if !postalCode.isEmpty && (postalCode.count != 5 || !postalCode.allSatisfy(\.isNumber)) {
            return "Le code postal compte 5 chiffres."
        }
        return nil
    }

    private func binding(_ keyPath: WritableKeyPath<Profile, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" },
                set: { draft[keyPath: keyPath] = $0 })
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(draft)
            dismiss()
        } catch {
            errorMessage = "Ces informations n'ont pas pu être enregistrées : "
                + error.localizedDescription
        }
    }
}
