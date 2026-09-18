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

    @MainActor
    public func signMandate() async {
        isWorking = true
        defer { isWorking = false }
        do { profile = try await repository.signBillingMandate() }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    public func deleteAccount() async {
        isWorking = true
        defer { isWorking = false }
        do { try await repository.deleteAccount() }
        catch { errorMessage = error.localizedDescription }
    }
}

public struct ProfileView: View {
    @State private var model: ProfileViewModel
    @State private var confirmsDeletion = false
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
            Theme.Palette.canvas.ignoresSafeArea()

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

                    SecondaryActionButton("Conditions générales", systemImage: "doc.text") {}
                    SecondaryActionButton("Confidentialité", systemImage: "lock") {}
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
        .confirmationDialog("Supprimer définitivement votre compte ?",
                            isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { Task { await model.deleteAccount() } }
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
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color(hex: 0x9EEBD3)))

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
                    PrimaryActionButton("Signer le mandat") {
                        Task { await model.signMandate() }
                    }
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
