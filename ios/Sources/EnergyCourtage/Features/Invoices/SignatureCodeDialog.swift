import SwiftUI

/// "Vous signez": what is being signed, by whom, and the six-digit code that
/// arrived by SMS. A centred card over the dimmed document, as in the source
/// app, so the document stays visible behind what is being agreed to.
public struct SignatureCodeDialog: View {
    @State private var code = ""
    @FocusState private var focused: Bool

    private let documentTitle: String
    private let amount: String
    private let signerName: String
    private let sentTo: String?
    private let error: String?
    private let isWorking: Bool
    private let onSubmit: (String) -> Void
    private let onResend: () -> Void
    private let onCancel: () -> Void

    public init(documentTitle: String, amount: String, signerName: String,
                sentTo: String?, error: String?, isWorking: Bool,
                onSubmit: @escaping (String) -> Void,
                onResend: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.documentTitle = documentTitle; self.amount = amount
        self.signerName = signerName; self.sentTo = sentTo; self.error = error
        self.isWorking = isWorking
        self.onSubmit = onSubmit; self.onResend = onResend; self.onCancel = onCancel
    }

    private static let length = 6
    private var isComplete: Bool { code.count == Self.length }

    /// "1300.00" -> "1 300,00 €"
    public static func euros(_ amount: String) -> String {
        guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
            return "\(amount) €"
        }
        return value.formatted(.currency(code: "EUR").locale(Locale(identifier: "fr_FR")))
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { focused = false }

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Vous signez")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)

                    VStack(spacing: Theme.Spacing.m) {
                        summaryRow("Document", documentTitle)
                        summaryRow("Montant", amount)
                        summaryRow("En tant que", signerName)
                    }
                    .padding(Theme.Spacing.l)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .stroke(Theme.Palette.hairline, lineWidth: 1)
                    )

                    Text(sentTo.map { "Code envoyé au \($0)" } ?? "Code envoyé par SMS")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    digits

                    if let error {
                        Text(error)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        if isComplete { onSubmit(code) }
                    } label: {
                        Text(isWorking ? "Signature…" : "Signer")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                    .fill(Theme.Palette.brand.opacity(isComplete && !isWorking ? 1 : 0.45))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isComplete || isWorking)

                    Button("Annuler", action: onCancel)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(Theme.Spacing.xl)

                Divider()

                HStack {
                    Label("Horodaté", systemImage: "lock")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.successText)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.Palette.successSoft))
                    Spacer()
                    Button("Renvoyer le code") {
                        code = ""
                        onResend()
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.brand)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.m)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.modal, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .padding(.horizontal, Theme.Spacing.xl)
        }
        .onAppear { focused = true }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .font(Theme.Typography.secondary)
    }

    /// Six boxes drawn over one hidden field, so the keyboard, paste and the
    /// iOS "code from Messages" suggestion all work as on a single field.
    private var digits: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("Code reçu par SMS")
                .onChange(of: code) { _, value in
                    let cleaned = String(value.filter(\.isNumber).prefix(Self.length))
                    if cleaned != value { code = cleaned }
                    // an autofilled code signs at once, as banking apps do
                    if cleaned.count == Self.length && !isWorking { onSubmit(cleaned) }
                }

            HStack(spacing: Theme.Spacing.s) {
                ForEach(0..<Self.length, id: \.self) { index in
                    let chars = Array(code)
                    let isCurrent = index == chars.count && focused
                    Text(index < chars.count ? String(chars[index]) : "·")
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .foregroundStyle(index < chars.count ? Theme.Palette.textPrimary
                                                            : Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(index <= chars.count ? Theme.Palette.surface : Theme.Palette.track.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(error != nil ? Theme.Palette.destructive
                                        : (index < chars.count || isCurrent)
                                            ? Theme.Palette.textPrimary : Theme.Palette.hairline,
                                        lineWidth: isCurrent ? 2 : 1)
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}
