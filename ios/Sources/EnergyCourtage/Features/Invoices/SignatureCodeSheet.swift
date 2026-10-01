import SwiftUI

/// "Saisissez le code reçu par SMS". Six digits, filled in by iOS from the
/// message when the user taps the suggestion above the keyboard.
public struct SignatureCodeSheet: View {
    @State private var code = ""
    @FocusState private var focused: Bool

    private let sentTo: String?
    private let error: String?
    private let isWorking: Bool
    private let onSubmit: (String) -> Void
    private let onResend: () -> Void

    public init(sentTo: String?, error: String?, isWorking: Bool,
                onSubmit: @escaping (String) -> Void, onResend: @escaping () -> Void) {
        self.sentTo = sentTo; self.error = error; self.isWorking = isWorking
        self.onSubmit = onSubmit; self.onResend = onResend
    }

    private var isComplete: Bool { code.count == 6 }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Code de signature")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            Text(sentTo.map { "Un code à 6 chiffres a été envoyé par SMS au \($0). Il est valable 10 minutes." }
                 ?? "Un code à 6 chiffres vous a été envoyé par SMS. Il est valable 10 minutes.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .stroke(error == nil ? Theme.Palette.hairline : Theme.Palette.destructive,
                                lineWidth: 1)
                )
                .focused($focused)
                .onChange(of: code) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { code = digits }
                    // the autofilled code submits itself, as banking apps do
                    if digits.count == 6 && !isWorking { onSubmit(digits) }
                }
                .accessibilityLabel("Code reçu par SMS")

            if let error {
                Text(error)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.destructive)
            }

            PrimaryActionButton(isWorking ? "Vérification…" : "Valider et signer") {
                if isComplete { onSubmit(code) }
            }
            .disabled(!isComplete || isWorking)
            .opacity(isComplete ? 1 : 0.5)

            Button("Je n'ai pas reçu le code — renvoyer") {
                code = ""
                onResend()
            }
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.brand)
            .frame(maxWidth: .infinity)
        }
        .padding(Theme.Spacing.xl)
        .onAppear { focused = true }
    }
}
