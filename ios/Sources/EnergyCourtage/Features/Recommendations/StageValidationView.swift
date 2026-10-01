import SwiftUI

/// What "Valider l'étape" opens. The reward stage asks for the services and
/// the payout; every other stage asks for the comment the apporteur will read.
public struct StageValidationView: View {
    private let recommendation: Recommendation
    private let stage: Stage
    private let loadBreakdown: () async -> RewardBreakdown
    private let onComment: (String) async throws -> Void
    private let onReward: (RewardStageForm) async throws -> Void

    public init(recommendation: Recommendation, stage: Stage,
                loadBreakdown: @escaping () async -> RewardBreakdown,
                onComment: @escaping (String) async throws -> Void,
                onReward: @escaping (RewardStageForm) async throws -> Void) {
        self.recommendation = recommendation; self.stage = stage
        self.loadBreakdown = loadBreakdown
        self.onComment = onComment; self.onReward = onReward
    }

    public var body: some View {
        if stage.isRewardTrigger {
            RewardStageView(loadBreakdown: loadBreakdown, onValidate: onReward)
        } else {
            StageCommentView(
                stageLabel: stage.label,
                initialText: StageCommentTemplate.render(stage.commentTemplate, for: recommendation),
                onValidate: onComment
            )
        }
    }
}

// MARK: - Shared chrome

/// "‹ Title" at the top, "Annuler / Valider l'étape" pinned at the bottom.
private struct ValidationScaffold<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let isWorking: Bool
    let canValidate: Bool
    let error: String?
    let onValidate: () -> Void
    let content: Content

    // Written out: the private @Environment above would make the synthesized
    // initializer private, and the two screens below could not call it.
    init(title: String, isWorking: Bool, canValidate: Bool, error: String?,
         onValidate: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title; self.isWorking = isWorking; self.canValidate = canValidate
        self.error = error; self.onValidate = onValidate
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.m) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Retour")
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.m)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    content
                }
                .padding(Theme.Spacing.gutter)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: Theme.Spacing.s) {
                if let error {
                    Text(error)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Theme.Spacing.m) {
                    Spacer()
                    Button("Annuler") { dismiss() }
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Spacing.l)
                    Button(action: onValidate) {
                        Text(isWorking ? "Validation…" : "Valider l'étape")
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
                    .disabled(!canValidate || isWorking)
                    .opacity(canValidate ? 1 : 0.5)
                }
            }
            .padding(Theme.Spacing.gutter)
            .background(Theme.Palette.surface)
            .overlay(alignment: .top) { Divider() }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

// MARK: - Comment

/// "Commentaire pour l'étape « … »". Opens on the stage's own wording so the
/// usual case is one tap; whatever is left here is what the apporteur reads.
public struct StageCommentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isWorking = false
    @State private var error: String?

    private let stageLabel: String
    private let onValidate: (String) async throws -> Void

    public init(stageLabel: String, initialText: String,
                onValidate: @escaping (String) async throws -> Void) {
        self.stageLabel = stageLabel
        self.onValidate = onValidate
        _text = State(initialValue: initialText)
    }

    public var body: some View {
        ValidationScaffold(
            title: "Commentaire pour l'étape \"\(stageLabel)\"",
            isWorking: isWorking,
            canValidate: true,
            error: error,
            onValidate: validate
        ) {
            Text("Ce message sera enregistré avec le changement d'étape")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textPrimary)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Commentaire")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                TextEditor(text: $text)
                    .font(Theme.Typography.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.m)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                            .fill(Theme.Palette.track.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                            .stroke(Theme.Palette.hairline, lineWidth: 1)
                    )
                    .accessibilityLabel("Commentaire")
            }
        }
    }

    private func validate() {
        isWorking = true
        error = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await onValidate(text)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Reward

/// "Validation de l'étape" on the reward stage: the services, the totals they
/// add up to, how the reward is paid, and a word for the apporteur.
public struct RewardStageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form = RewardStageForm()
    @State private var isWorking = false
    @State private var error: String?
    @State private var loaded = false
    @State private var showsTurnoverHelp = false

    private let loadBreakdown: () async -> RewardBreakdown
    private let onValidate: (RewardStageForm) async throws -> Void

    public init(loadBreakdown: @escaping () async -> RewardBreakdown,
                onValidate: @escaping (RewardStageForm) async throws -> Void) {
        self.loadBreakdown = loadBreakdown
        self.onValidate = onValidate
    }

    private var maxText: String { "Montant maximum : \(RewardStageForm.format(form.maxReward)) EUR" }

    public var body: some View {
        ValidationScaffold(
            title: "Validation de l'étape",
            isWorking: isWorking,
            canValidate: loaded && form.problem == nil,
            error: error ?? (loaded ? form.problem : nil),
            onValidate: validate
        ) {
            banner

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Prestations souscrites par le filleul")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Cochez celles qui ont été signées. Vous pouvez corriger une ligne ou en ajouter une.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            ForEach($form.lines) { $line in
                lineEditor($line, number: (form.lines.firstIndex { $0.id == line.id } ?? 0) + 1)
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) { form.lines.append(RewardLineDraft()) }
            } label: {
                Label("Ajouter une prestation", systemImage: "plus")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(Theme.Palette.track.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Message pour l'apporteur (optionnel)")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                TextField("Un mot pour accompagner sa récompense", text: $form.message, axis: .vertical)
                    .lineLimit(3...6)
                    .font(Theme.Typography.body)
                    .padding(Theme.Spacing.l)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                            .stroke(Theme.Palette.hairline, lineWidth: 1)
                    )
            }

            totals
            payout
        }
        .task {
            guard !loaded else { return }
            let breakdown = await loadBreakdown()
            var restored = RewardStageForm(
                lines: breakdown.lines.map {
                    RewardLineDraft(label: $0.label, turnover: $0.turnover,
                                    reward: $0.reward, signed: $0.signed)
                },
                maxReward: breakdown.maxReward
            )
            if let method = breakdown.payoutMethod { restored.payoutMethod = method }
            form = restored
            loaded = true
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: "info.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.Palette.brand)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Étape de déclenchement des récompenses")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Cette étape déclenche automatiquement le système de récompenses. Veuillez remplir les informations ci-dessous.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(Theme.Palette.brandSoft)
        )
    }

    private func lineEditor(_ line: Binding<RewardLineDraft>, number: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text("Prestation \(number)")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if form.lines.count > 1 {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            form.lines.removeAll { $0.id == line.wrappedValue.id }
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Supprimer la prestation \(number)")
                }
                Button {
                    line.wrappedValue.signed.toggle()
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: line.wrappedValue.signed ? "checkmark.square.fill" : "square")
                            .foregroundStyle(Theme.Palette.brand)
                        Text("Signée")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .stroke(Theme.Palette.brand.opacity(0.6), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(line.wrappedValue.signed ? .isSelected : [])
            }

            LabelledField("Intitulé de la prestation") {
                TextField("Ex : mandat de vente, étude de financement...", text: line.label)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Montant du chiffre d'affaires")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Button { showsTurnoverHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Aide")
                }
                if showsTurnoverHelp {
                    Text("Ce que la prestation rapporte à l'entreprise. Il sert au suivi, pas au calcul de la récompense.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                amountField(line.turnoverText, unit: "EUR")
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Récompense prévue si cette prestation est signée")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                amountField(line.rewardText, unit: "EUR TTC")
                Text(maxText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private func amountField(_ text: Binding<String>, unit: String) -> some View {
        HStack {
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
            Text(unit)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 14)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .stroke(Theme.Palette.hairline, lineWidth: 1)
        )
    }

    private func readOnlyAmount(_ amount: Decimal, unit: String) -> some View {
        HStack {
            Text(RewardStageForm.format(amount))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Text(unit)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .fill(Theme.Palette.track)
        )
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Montant du chiffre d'affaires")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            readOnlyAmount(form.turnoverTotal, unit: "EUR")
            Text("Calculé à partir des prestations cochées")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)

            Text("Montant de la récompense")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.top, Theme.Spacing.s)
            readOnlyAmount(form.rewardTotal, unit: "EUR TTC")
            Text(maxText)
                .font(Theme.Typography.caption)
                .foregroundStyle(form.rewardTotal > form.maxReward
                                 ? Theme.Palette.destructive : Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Palette.grouped.opacity(0.5))
        )
    }

    private var payout: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Versée en")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            ForEach(PayoutMethod.allCases) { method in
                Button {
                    form.payoutMethod = method
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: form.payoutMethod == method
                              ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(form.payoutMethod == method
                                             ? Theme.Palette.brand : Theme.Palette.pendingRing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.label)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(maxText)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(Theme.Spacing.l)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .stroke(form.payoutMethod == method
                                    ? Theme.Palette.textPrimary.opacity(0.6) : Theme.Palette.hairline,
                                    lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(form.payoutMethod == method ? .isSelected : [])
            }
        }
    }

    private func validate() {
        guard form.problem == nil else { return }
        isWorking = true
        error = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await onValidate(form)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
