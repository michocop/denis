import SwiftUI
import Observation

@Observable
public final class MembersViewModel {
    public private(set) var members: [MemberOverview] = []
    public private(set) var errorMessage: String?
    public var query = ""
    public var showPendingOnly = false
    public var isLoading = false
    public var lastInvite: Invite?

    private let repository: AdminRepository
    public init(repository: AdminRepository) { self.repository = repository }

    public var visibleMembers: [MemberOverview] {
        members
            .filter { !showPendingOnly || $0.isPending }
            .filter { query.isEmpty
                      || $0.fullName.localizedCaseInsensitiveContains(query)
                      || $0.email.localizedCaseInsensitiveContains(query) }
            // Those waiting on a decision first: they are blocked on the admin,
            // not the other way round.
            .sorted { lhs, rhs in
                if lhs.isPending != rhs.isPending { return lhs.isPending }
                return (lhs.lastRecommendationAt ?? .distantPast)
                     > (rhs.lastRecommendationAt ?? .distantPast)
            }
    }

    public var pendingCount: Int { members.filter(\.isPending).count }

    @MainActor
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            members = try await repository.members()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    public func approve(_ member: MemberOverview) async {
        do { try await repository.approve(profileID: member.id); await load() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Recording that payment details are held elsewhere. Nothing here ever
    /// touches an account number: the app only needs to know whether someone
    /// CAN be paid, which is a boolean, and the details themselves live in the
    /// client's banking system where the transfer is actually made.
    @MainActor
    public func setBankDetails(_ member: MemberOverview, onFile: Bool) async {
        do {
            try await repository.setBankDetailsOnFile(profileID: member.id,
                                                      onFile: onFile, reference: nil)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    public func setStatus(_ member: MemberOverview, to status: String) async {
        do { try await repository.setStatus(profileID: member.id, status: status); await load() }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    public func invite(email: String?, role: UserRole, autoActivate: Bool) async {
        do { lastInvite = try await repository.createInvite(email: email, role: role,
                                                            autoActivate: autoActivate) }
        catch { errorMessage = error.localizedDescription }
    }
}

/// Pierre-Louis's side: who is in, who is waiting, and who has gone quiet.
public struct MembersView: View {
    @State private var model: MembersViewModel
    @State private var showsInvite = false

    public init(model: MembersViewModel) { _model = State(wrappedValue: model) }

    public var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Apporteurs")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    SearchField("Rechercher un apporteur", text: $model.query)

                    if model.pendingCount > 0 {
                        Toggle(isOn: $model.showPendingOnly) {
                            Text("\(model.pendingCount) en attente de validation")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .tint(Theme.Palette.brand)
                        .padding(Theme.Spacing.l)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.button,
                                             style: .continuous)
                                .fill(Theme.Palette.rewardSoft)
                        )
                    }

                    PrimaryActionButton("Inviter un apporteur") { showsInvite = true }

                    ForEach(model.visibleMembers) { member in
                        MemberRow(
                            member: member,
                            onApprove: { Task { await model.approve(member) } },
                            onSuspend: { Task { await model.setStatus(member, to: "suspended") } },
                            onReactivate: { Task { await model.setStatus(member, to: "active") } },
                            onSetBankDetails: { onFile in
                                Task { await model.setBankDetails(member, onFile: onFile) }
                            }
                        )
                    }

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .refreshable { await model.load() }
        }
        .task { await model.load() }
        .sheet(isPresented: $showsInvite) {
            InviteSheet(lastInvite: model.lastInvite) { email, role, autoActivate in
                await model.invite(email: email, role: role, autoActivate: autoActivate)
            }
        }
    }
}

struct MemberRow: View {
    let member: MemberOverview
    let onApprove: () -> Void
    let onSuspend: () -> Void
    let onReactivate: () -> Void
    let onSetBankDetails: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                Text(member.initials)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.Palette.avatar))

                VStack(alignment: .leading, spacing: 2) {
                    Text(member.fullName)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(member.email)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.s)
                statusPill
            }

            HStack(spacing: Theme.Spacing.l) {
                metric("Actives", "\(member.activeRecommendations)")
                metric("Dû", HomeView.euros(member.owedTotal))
                metric("Versé", HomeView.euros(member.paidTotal))
            }

            // Two things that quietly block payment, surfaced before anyone
            // wonders why an apporteur has not been paid.
            if !member.hasMandate {
                flag("Mandat de facturation non signé", tint: Theme.Palette.rewardText)
            }
            if member.hasNeverRecommended && member.isActive {
                flag("Aucune recommandation envoyée", tint: Theme.Palette.textSecondary)
            }
            if !member.bankDetailsOnFile {
                flag("Coordonnées bancaires non renseignées", tint: Theme.Palette.rewardText)
            }

            HStack(spacing: Theme.Spacing.m) {
                if member.isPending {
                    Button("Valider", action: onApprove)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.brand)
                }
                Spacer()
                Menu {
                    if member.isActive {
                        Button("Suspendre", role: .destructive, action: onSuspend)
                    } else {
                        Button("Réactiver", action: onReactivate)
                    }
                    Divider()
                    if member.bankDetailsOnFile {
                        Button("Coordonnées bancaires manquantes") { onSetBankDetails(false) }
                    } else {
                        Button("Coordonnées bancaires enregistrées") { onSetBankDetails(true) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .accessibilityLabel("Actions pour \(member.fullName)")
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var statusPill: some View {
        let (text, bg, fg): (String, Color, Color) = {
            switch member.status {
            case "active":    return ("Actif", Theme.Palette.successSoft, Theme.Palette.successText)
            case "pending":   return ("En attente", Theme.Palette.rewardSoft, Theme.Palette.rewardText)
            default:          return ("Suspendu", Theme.Palette.track, Theme.Palette.textSecondary)
            }
        }()
        return Text(text)
            .font(Theme.Typography.badge)
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(bg))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func flag(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13))
            Text(text).font(Theme.Typography.caption)
        }
        .foregroundStyle(tint)
    }
}

/// Creating an invitation. The code is shown once, big, because it gets read
/// out over the phone.
struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var role: UserRole = .apporteur
    @State private var autoActivate = true
    @State private var isWorking = false

    let lastInvite: Invite?
    let create: (String?, UserRole, Bool) async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if let invite = lastInvite {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text("Code d'invitation")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Text(invite.code)
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .textSelection(.enabled)
                            ShareLink(item: "Votre code d'invitation Trinity Énergie : \(invite.code)") {
                                Label("Partager le code", systemImage: "square.and.arrow.up")
                                    .font(Theme.Typography.body)
                            }
                        }
                        .padding(Theme.Spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    }

                    LabelledField("Email (facultatif)") {
                        TextField("Verrouille le code sur cette adresse", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    LabelledField("Rôle") {
                        Picker("Rôle", selection: $role) {
                            Text("Apporteur").tag(UserRole.apporteur)
                            Text("Administrateur").tag(UserRole.admin)
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle("Activer automatiquement", isOn: $autoActivate)
                        .tint(Theme.Palette.brand)
                        .font(Theme.Typography.body)

                    Text(autoActivate
                         ? "La personne accède à l'application dès qu'elle utilise le code."
                         : "La personne devra être validée par un administrateur après son inscription.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    PrimaryActionButton(isWorking ? "Création…" : "Générer le code") {
                        Task {
                            isWorking = true
                            await create(email.isEmpty ? nil : email, role, autoActivate)
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(Theme.Palette.canvas)
            .navigationTitle("Inviter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.Actions.close) { dismiss() }
                }
            }
        }
    }
}
