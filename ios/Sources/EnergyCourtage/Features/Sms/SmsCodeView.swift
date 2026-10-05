import SwiftUI

/// Six digits, as six boxes. The field underneath is a real text field with
/// the one-time-code content type, so iOS offers the code from Messages above
/// the keyboard and a paste lands whole.
struct SmsCodeField: View {
    @Binding var code: String
    var isError: Bool
    var onComplete: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: Binding(
                get: { code },
                set: { typed in
                    let digits = MobileNumber.code(typed)
                    code = digits
                    if digits.count == 6 { onComplete(digits) }
                }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("Code reçu par SMS, six chiffres")

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    let digit = index < code.count
                        ? String(code[code.index(code.startIndex, offsetBy: index)]) : ""
                    let isCurrent = focused && index == min(code.count, 5)
                    Text(digit)
                        .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Theme.Palette.grouped,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isError ? Theme.Palette.destructive
                                              : isCurrent ? Theme.Palette.brand : Theme.Palette.hairline,
                                              lineWidth: isCurrent || isError ? 1.5 : 1)
                        )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .animation(.snappy(duration: 0.18), value: code)
    }
}

/// Enters a code sent by SMS: for a signature, or to prove a number. The code
/// was sent before this appears; this checks it, and sends another on request
/// once the half-minute the server enforces has passed.
public struct SmsCodeView: View {
    private let title: String
    private let explanation: String
    private let resend: () async throws -> SmsChallenge
    private let confirm: (String) async throws -> SmsConfirmation
    private let onConfirmed: () -> Void
    private let demoHint: String?

    @State private var maskedPhone: String
    @State private var code = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var resendAvailableAt = Date.now.addingTimeInterval(30)
    @State private var now = Date.now

    public init(title: String, explanation: String, maskedPhone: String, demoHint: String? = nil,
                resend: @escaping () async throws -> SmsChallenge,
                confirm: @escaping (String) async throws -> SmsConfirmation,
                onConfirmed: @escaping () -> Void) {
        self.title = title
        self.explanation = explanation
        self.demoHint = demoHint
        self.resend = resend
        self.confirm = confirm
        self.onConfirmed = onConfirmed
        _maskedPhone = State(initialValue: maskedPhone)
    }

    private var secondsBeforeResend: Int { max(0, Int(resendAvailableAt.timeIntervalSince(now).rounded(.up))) }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Image(systemName: "message.badge.filled.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Palette.brand)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("\(explanation) Code envoyé au \(maskedPhone).")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SmsCodeField(code: $code, isError: errorMessage != nil) { digits in
                Task { await check(digits) }
            }
            .disabled(isWorking)

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let demoHint {
                Text(demoHint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            PrimaryActionButton(isWorking ? "Vérification…" : "Valider") {
                Task { await check(code) }
            }
            .disabled(code.count != 6 || isWorking)
            .opacity(code.count == 6 ? 1 : 0.6)

            HStack {
                Spacer()
                Button(secondsBeforeResend > 0 ? "Renvoyer un code dans \(secondsBeforeResend) s"
                                               : "Renvoyer un code") {
                    Task { await sendAgain() }
                }
                .font(Theme.Typography.label)
                .foregroundStyle(secondsBeforeResend > 0 ? Theme.Palette.textSecondary : Theme.Palette.brand)
                .disabled(secondsBeforeResend > 0 || isWorking)
                .monospacedDigit()
                Spacer()
            }
        }
        .padding(Theme.Spacing.cardPadding)
        .cardSurface()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
    }

    @MainActor
    private func check(_ digits: String) async {
        guard digits.count == 6, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let answer = try await confirm(digits)
            if answer.ok {
                errorMessage = nil
                onConfirmed()
                return
            }
            code = ""
            var message = answer.message ?? "Code incorrect."
            if answer.reason == "wrong", let left = answer.attemptsLeft {
                message += left == 1 ? " Dernier essai." : " Encore \(left) essais."
            }
            if answer.needsNewCode { resendAvailableAt = .now }
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func sendAgain() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let challenge = try await resend()
            if let masked = challenge.maskedPhone { maskedPhone = masked }
            code = ""
            errorMessage = nil
            resendAvailableAt = .now.addingTimeInterval(30)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Proves a mobile number: the number, then the code sent to it. A signature
/// is only ever confirmed by a code sent to a number proven this way.
public struct PhoneVerificationView: View {
    @Environment(\.dismiss) private var dismiss
    private let repository: SmsRepository
    private let onVerified: () -> Void
    private let demoHint: String?

    @State private var phone: String
    @State private var sentTo: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    public init(repository: SmsRepository, initialPhone: String = "", demoHint: String? = nil,
                onVerified: @escaping () -> Void) {
        self.repository = repository
        self.onVerified = onVerified
        self.demoHint = demoHint
        _phone = State(initialValue: initialPhone)
    }

    private var number: String? { MobileNumber.e164(phone) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let sentTo {
                    SmsCodeView(
                        title: "Saisissez le code",
                        explanation: "Il prouve que ce numéro est le vôtre.",
                        maskedPhone: sentTo,
                        demoHint: demoHint,
                        resend: { try await repository.requestCode(.verifyPhone, invoiceID: nil, phone: number) },
                        confirm: { try await repository.confirm(.verifyPhone, code: $0, invoiceID: nil) },
                        onConfirmed: onVerified)
                    Button("Changer de numéro") { self.sentTo = nil }
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                } else {
                    numberCard
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .background(BrandBackground())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuler") { dismiss() }
            }
        }
    }

    private var numberCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Palette.brand)
                    .symbolRenderingMode(.hierarchical)
                Text("Votre mobile")
                    .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Vos factures se signent avec un code reçu par SMS sur ce numéro. Il ne sert à rien d'autre.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabelledField("Numéro de mobile") {
                TextField("06 12 34 56 78", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !phone.isEmpty && number == nil {
                Text("Un numéro de mobile : 06 ou 07, ou international avec son +.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            PrimaryActionButton(isWorking ? "Envoi…" : "Recevoir un code") {
                Task { await send() }
            }
            .disabled(number == nil || isWorking)
            .opacity(number == nil ? 0.6 : 1)
        }
        .padding(Theme.Spacing.cardPadding)
        .cardSurface()
    }

    @MainActor
    private func send() async {
        guard let number else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let challenge = try await repository.requestCode(.verifyPhone, invoiceID: nil, phone: number)
            errorMessage = nil
            sentTo = challenge.maskedPhone ?? number
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
