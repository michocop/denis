import SwiftUI

/// A horizontal shake, for a code that was wrong.
private struct Shake: GeometryEffect {
    var travel: CGFloat = 9
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Six digits, as six boxes. The field underneath is a real text field with
/// the one-time-code content type, so iOS offers the code from Messages above
/// the keyboard and a paste lands whole.
struct SmsCodeField: View {
    enum Phase: Equatable { case entering, checking, wrong, accepted }

    @Binding var code: String
    var phase: Phase
    /// Bumped on every wrong code, to replay the shake.
    var shakes: Int
    var onComplete: (String) -> Void
    @FocusState private var focused: Bool

    private func tint(at index: Int) -> Color {
        switch phase {
        case .accepted: Theme.Palette.success
        case .wrong: Theme.Palette.destructive
        case .checking: Theme.Palette.brand.opacity(0.7)
        case .entering:
            focused && index == min(code.count, 5) ? Theme.Palette.brand : Theme.Palette.hairline
        }
    }

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
                    let isCurrent = phase == .entering && focused && index == min(code.count, 5)
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(phase == .accepted ? Theme.Palette.successSoft : Theme.Palette.grouped)
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(tint(at: index), lineWidth: isCurrent || phase != .entering ? 1.5 : 1)
                        if !digit.isEmpty {
                            Text(digit)
                                .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                                .monospacedDigit()
                                .foregroundStyle(phase == .accepted ? Theme.Palette.successText
                                                                    : Theme.Palette.textPrimary)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        } else if isCurrent {
                            Capsule()
                                .fill(Theme.Palette.brand)
                                .frame(width: 2, height: 26)
                                .phaseAnimator([1.0, 0.15]) { caret, opacity in caret.opacity(opacity) }
                                    animation: { _ in .easeInOut(duration: 0.55) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .scaleEffect(phase == .accepted ? 1.04 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.6)
                                .delay(phase == .accepted ? Double(index) * 0.04 : 0),
                               value: phase)
                    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: code)
                }
            }
            .modifier(Shake(animatableData: CGFloat(shakes)))
            .animation(.linear(duration: 0.45), value: shakes)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
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
    @State private var phase: SmsCodeField.Phase = .entering
    @State private var shakes = 0
    @State private var resendAvailableAt = Date.now.addingTimeInterval(30)
    @State private var now = Date.now
    @State private var resent = false

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
    private var isBusy: Bool { phase == .checking || phase == .accepted }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ZStack {
                    Circle()
                        .fill(phase == .accepted ? Theme.Palette.successSoft : Theme.Palette.brandSoft)
                        .frame(width: 52, height: 52)
                    Image(systemName: phase == .accepted ? "checkmark" : "message.badge.filled.fill")
                        .font(.system(size: phase == .accepted ? 24 : 22, weight: .semibold))
                        .foregroundStyle(phase == .accepted ? Theme.Palette.success : Theme.Palette.brand)
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: phase == .accepted)
                }
                .padding(.bottom, 4)

                Text(phase == .accepted ? "C'est bon." : title)
                    .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.opacity)
                Text("\(explanation) Code envoyé au \(maskedPhone).")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }

            SmsCodeField(code: $code, phase: phase, shakes: shakes) { digits in
                Task { await check(digits) }
            }
            .disabled(isBusy)

            Group {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.Palette.destructive)
                } else if resent {
                    Label("Nouveau code envoyé.", systemImage: "paperplane.fill")
                        .foregroundStyle(Theme.Palette.successText)
                } else if let demoHint {
                    Text(demoHint).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .font(Theme.Typography.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.move(edge: .top).combined(with: .opacity))

            PrimaryActionButton(phase == .checking ? "Vérification…" : "Valider") {
                Task { await check(code) }
            }
            .disabled(code.count != 6 || isBusy)
            .opacity(code.count == 6 && !isBusy ? 1 : 0.6)

            HStack {
                Spacer()
                Button {
                    Task { await sendAgain() }
                } label: {
                    if secondsBeforeResend > 0 {
                        Text("Renvoyer un code dans \(secondsBeforeResend) s")
                            .contentTransition(.numericText(countsDown: true))
                    } else {
                        Text("Renvoyer un code")
                    }
                }
                .font(Theme.Typography.label)
                .foregroundStyle(secondsBeforeResend > 0 ? Theme.Palette.textSecondary : Theme.Palette.brand)
                .disabled(secondsBeforeResend > 0 || isBusy)
                .monospacedDigit()
                .animation(.snappy, value: secondsBeforeResend)
                Spacer()
            }
        }
        .padding(Theme.Spacing.cardPadding)
        .cardSurface()
        .animation(.smooth(duration: 0.3), value: errorMessage)
        .animation(.smooth(duration: 0.3), value: phase)
        .animation(.smooth(duration: 0.3), value: resent)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .sensoryFeedback(.error, trigger: shakes)
        .sensoryFeedback(.success, trigger: phase == .accepted)
    }

    @MainActor
    private func check(_ digits: String) async {
        guard digits.count == 6, !isBusy else { return }
        phase = .checking
        resent = false
        do {
            let answer = try await confirm(digits)
            if answer.ok {
                errorMessage = nil
                phase = .accepted
                // long enough to see the boxes turn green, short enough not to wait
                try? await Task.sleep(for: .milliseconds(650))
                onConfirmed()
                return
            }
            var message = answer.message ?? "Code incorrect."
            if answer.reason == "wrong", let left = answer.attemptsLeft {
                message += left == 1 ? " Dernier essai." : " Encore \(left) essais."
            }
            if answer.needsNewCode { resendAvailableAt = .now }
            fail(message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    @MainActor
    private func fail(_ message: String) {
        errorMessage = message
        phase = .wrong
        shakes += 1
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            code = ""
            if phase == .wrong { phase = .entering }
        }
    }

    @MainActor
    private func sendAgain() async {
        phase = .checking
        defer { if phase == .checking { phase = .entering } }
        do {
            let challenge = try await resend()
            if let masked = challenge.maskedPhone { maskedPhone = masked }
            code = ""
            errorMessage = nil
            resent = true
            resendAvailableAt = .now.addingTimeInterval(30)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A number, then the code sent to it. Used to prove a number from the
/// profile, and inline before an apporteur's first signature -- where the one
/// signing code both proves the number and confirms the signature.
public struct PhoneVerificationView: View {
    @Environment(\.dismiss) private var dismiss

    private let title: String
    private let explanation: String
    private let codeTitle: String
    private let codeExplanation: String
    private let send: (_ phone: String, _ resend: Bool) async throws -> SmsChallenge
    private let confirm: (String) async throws -> SmsConfirmation
    private let onConfirmed: () -> Void
    private let onCancel: (() -> Void)?
    private let demoHint: String?

    @State private var phone: String
    @State private var sentTo: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    /// Proving a number from the profile.
    public init(repository: SmsRepository, initialPhone: String = "", demoHint: String? = nil,
                onVerified: @escaping () -> Void) {
        self.init(title: "Votre mobile",
                  explanation: "Vos factures se signent avec un code reçu par SMS sur ce numéro. Il ne sert à rien d'autre.",
                  codeTitle: "Saisissez le code",
                  codeExplanation: "Il prouve que ce numéro est le vôtre.",
                  initialPhone: initialPhone, demoHint: demoHint,
                  send: { phone, resend in
                      try await repository.requestCode(.verifyPhone, invoiceID: nil, phone: phone, resend: resend)
                  },
                  confirm: { try await repository.confirm(.verifyPhone, code: $0, invoiceID: nil) },
                  onConfirmed: onVerified)
    }

    public init(title: String, explanation: String, codeTitle: String, codeExplanation: String,
                initialPhone: String = "", demoHint: String? = nil,
                send: @escaping (_ phone: String, _ resend: Bool) async throws -> SmsChallenge,
                confirm: @escaping (String) async throws -> SmsConfirmation,
                onConfirmed: @escaping () -> Void,
                onCancel: (() -> Void)? = nil) {
        self.title = title
        self.explanation = explanation
        self.codeTitle = codeTitle
        self.codeExplanation = codeExplanation
        self.demoHint = demoHint
        self.send = send
        self.confirm = confirm
        self.onConfirmed = onConfirmed
        self.onCancel = onCancel
        _phone = State(initialValue: MobileNumber.formatted(initialPhone))
    }

    private var number: String? { MobileNumber.e164(phone) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let sentTo {
                    SmsCodeView(
                        title: codeTitle,
                        explanation: codeExplanation,
                        maskedPhone: sentTo,
                        demoHint: demoHint,
                        resend: { try await send(number ?? phone, true) },
                        confirm: confirm,
                        onConfirmed: onConfirmed)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { self.sentTo = nil }
                    } label: {
                        Label("Changer de numéro", systemImage: "arrow.uturn.backward")
                    }
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                } else {
                    numberCard
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(BrandBackground())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuler") {
                    if let onCancel { onCancel() } else { dismiss() }
                }
            }
        }
    }

    private var numberCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ZStack {
                    Circle().fill(Theme.Palette.brandSoft).frame(width: 52, height: 52)
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.Palette.brand)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: isWorking)
                }
                .padding(.bottom, 4)
                Text(title)
                    .font(Theme.Typography.display(26, .semibold, relativeTo: .title))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(explanation)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabelledField("Numéro de mobile") {
                HStack {
                    TextField("06 12 34 56 78", text: Binding(
                        get: { phone },
                        set: { typed in
                            // backspace over a space would leave the digits as they
                            // were, and the formatting would put the space back
                            var raw = typed
                            if typed.count < phone.count,
                               typed.filter(\.isNumber) == phone.filter(\.isNumber) {
                                raw = String(typed.dropLast())
                            }
                            phone = MobileNumber.formatted(raw)
                        }))
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    if number != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Palette.success)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: number != nil)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !phone.isEmpty && number == nil {
                Text("Un numéro de mobile : 06 ou 07, ou international avec son +.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            PrimaryActionButton(isWorking ? "Envoi…" : "Recevoir un code") {
                Task { await sendCode() }
            }
            .disabled(number == nil || isWorking)
            .opacity(number == nil ? 0.6 : 1)
        }
        .padding(Theme.Spacing.cardPadding)
        .cardSurface()
        .animation(.smooth(duration: 0.3), value: errorMessage)
    }

    @MainActor
    private func sendCode() async {
        guard let number else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let challenge = try await send(number, false)
            errorMessage = nil
            guard challenge.required else {
                onConfirmed()   // a signing window already covers it: no SMS
                return
            }
            withAnimation(.smooth(duration: 0.35)) { sentTo = challenge.maskedPhone ?? number }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
