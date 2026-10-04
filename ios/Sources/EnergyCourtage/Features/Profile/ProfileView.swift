import SwiftUI
import Observation

@Observable
public final class ProfileViewModel {
    public private(set) var profile: Profile?
    public private(set) var errorMessage: String?
    public var isWorking = false

    private let repository: ProfileRepository
    public init(repository: ProfileRepository) { self.repository = repository }

    @MainActor
    public func load() async {
        do {
            profile = try await repository.currentProfile()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True once the server has deleted the account, so the screen can sign
    /// out: the login no longer exists, and staying on the tabs left the person
    /// looking at an account that was gone until they next relaunched.
    @MainActor
    public func save(_ updated: Profile) async throws {
        profile = try await repository.save(updated)
    }

    @MainActor
    public func deleteAccount() async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.deleteAccount()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

public struct ProfileView: View {
    @State private var model: ProfileViewModel
    @State private var confirmsDeletion = false
    @State private var showsMandate = false
    @State private var shownDocument: LegalDocumentKey?
    @State private var showsBillingDetails = false
    private let dependencies: Dependencies
    private let onSignOut: () -> Void

    public init(model: ProfileViewModel, dependencies: Dependencies,
                onSignOut: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.dependencies = dependencies
        self.onSignOut = onSignOut
    }

    public var body: some View {
        // Wrapped in a NavigationStack so the console and the statement push
        // from here: adding tabs would have broken the five-tab layout the
        // source app has.
        NavigationStack {
        ZStack {
            BrandBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Profil")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    if let profile = model.profile {
                        identity(profile)

                        if profile.role.isAdmin {
                            NavigationLink {
                                MembersView(model: MembersViewModel(
                                    repository: dependencies.admin))
                            } label: {
                                consoleRow("Apporteurs", icon: "person.2")
                            }
                            NavigationLink {
                                PayablesView(model: PayablesViewModel(
                                    repository: dependencies.admin))
                            } label: {
                                consoleRow("À régler", icon: "eurosign.circle")
                            }
                        } else {
                            NavigationLink {
                                CommissionsView(
                                    model: CommissionsViewModel(
                                        repository: dependencies.commissions),
                                    apporteurName: profile.fullName
                                )
                            } label: {
                                consoleRow("Mes gains", icon: "eurosign.circle")
                            }
                            billing(profile)
                        }
                    }

                    // Both were empty closures: required documents, and the
                    // buttons for them did nothing.
                    SecondaryActionButton("Conditions générales", systemImage: "doc.text") {
                        shownDocument = LegalDocumentKey(id: "cgu")
                    }
                    SecondaryActionButton("Confidentialité", systemImage: "lock") {
                        shownDocument = LegalDocumentKey(id: "confidentialite")
                    }
                    SecondaryActionButton("Se déconnecter",
                                          systemImage: "rectangle.portrait.and.arrow.right",
                                          action: onSignOut)

                    // App Store guideline 5.1.1(v): an account created in the
                    // app must be deletable in the app.
                    Button(role: .destructive) { confirmsDeletion = true } label: {
                        Text("Supprimer mon compte")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.destructive)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showsBillingDetails) {
            if let profile = model.profile {
                BillingDetailsView(profile: profile) { try await model.save($0) }
            }
        }
        .sheet(item: $shownDocument) { key in
            LegalDocumentView(model: LegalViewModel(repository: dependencies.legal),
                              documentKey: key.id)
        }
        .sheet(isPresented: $showsMandate) {
            LegalDocumentView(model: LegalViewModel(repository: dependencies.legal),
                              documentKey: "mandat_facturation")
                .onDisappear { Task { await model.load() } }
        }
        .confirmationDialog("Supprimer définitivement votre compte ?",
                            isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                Task { if await model.deleteAccount() { onSignOut() } }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Vos recommandations et vos factures sont conservées pour des raisons légales, mais votre compte et vos données personnelles seront supprimés.")
        }
        }
    }

    private func consoleRow(_ title: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 24)
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 16)
        .cardSurface()
    }

    private func identity(_ profile: Profile) -> some View {
        HStack(spacing: Theme.Spacing.l) {
            Text(profile.initials)
                .font(Theme.Typography.display(22, .semibold, relativeTo: .title2))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.Palette.avatar))

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.fullName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(profile.email)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if let company = profile.companyName, !company.isEmpty {
                    Text(company)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func billing(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Facturation")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)

            Button { showsBillingDetails = true } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coordonnées sur vos factures")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        if profile.hasBillingAddress {
                            Text([profile.address, [profile.postalCode, profile.city]
                                    .compactMap { $0 }.joined(separator: " ")]
                                    .compactMap { $0 }.joined(separator: ", "))
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                        } else {
                            Text("Adresse à compléter")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.destructive)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Divider()

            HStack {
                Text("Régime de TVA")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(profile.vatLiable ? "Assujetti (20 %)" : "Franchise en base (293 B)")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            Divider()

            if profile.canBeInvoiced {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.success)
                    Text("Mandat de facturation signé")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text("Le mandat autorise Trinity Énergie à établir vos factures d'apport d'affaires en votre nom. Il doit être signé avant toute facturation.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Opens the document. It used to sign it outright, from
                    // under a two-line summary — which recorded a consent to
                    // something the person had never been shown.
                    PrimaryActionButton("Lire et signer le mandat") {
                        showsMandate = true
                    }
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
