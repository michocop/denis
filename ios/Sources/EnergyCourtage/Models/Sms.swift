import Foundation

/// What a code sent by SMS is for. The server binds each code to one purpose
/// (and, for a signature, to one invoice), so a code cannot be reused.
public enum SmsPurpose: String, Sendable {
    case verifyPhone = "verify_phone"
    case signInvoice = "sign_invoice"
    /// The apporteur contract and its annex, signed once at the first sign-in.
    case signContract = "sign_contract"
}

/// Whether signing needs a code, and whether this person can receive one.
public struct SmsStatus: Decodable, Equatable, Sendable {
    /// False until the company has set SMS up; signing then needs no code.
    public var smsRequired: Bool
    public var phoneVerified: Bool
    public var maskedPhone: String?

    public init(smsRequired: Bool, phoneVerified: Bool, maskedPhone: String? = nil) {
        self.smsRequired = smsRequired
        self.phoneVerified = phoneVerified
        self.maskedPhone = maskedPhone
    }
}

/// A code on its way.
public struct SmsChallenge: Decodable, Equatable, Sendable {
    /// False when no code is needed: the action goes ahead without one --
    /// SMS is not set up, or a code confirmed minutes ago still covers it.
    public var required: Bool
    public var maskedPhone: String?
    public var expiresAt: Date?
    /// A code confirmed in the last ten minutes covers this signature.
    public var session: Bool?
    /// The code already sent is still good, so no new SMS went out.
    public var reused: Bool?

    public init(required: Bool, maskedPhone: String? = nil, expiresAt: Date? = nil,
                session: Bool? = nil, reused: Bool? = nil) {
        self.required = required
        self.maskedPhone = maskedPhone
        self.expiresAt = expiresAt
        self.session = session
        self.reused = reused
    }
}

/// The server's answer to a code. A wrong code is an answer, not an error:
/// it is counted, and five of them retire the code.
public struct SmsConfirmation: Decodable, Equatable, Sendable {
    public var ok: Bool
    /// "wrong", "expired" or "locked" when `ok` is false.
    public var reason: String?
    public var message: String?
    public var attemptsLeft: Int?
    public var maskedPhone: String?

    public init(ok: Bool, reason: String? = nil, message: String? = nil,
                attemptsLeft: Int? = nil, maskedPhone: String? = nil) {
        self.ok = ok
        self.reason = reason
        self.message = message
        self.attemptsLeft = attemptsLeft
        self.maskedPhone = maskedPhone
    }

    /// This code can no longer be used: only a new one will do.
    public var needsNewCode: Bool { reason == "expired" || reason == "locked" }
}

public protocol SmsRepository: Sendable {
    func status() async throws -> SmsStatus
    /// Sends a code -- or not: the server reuses one still on its way unless
    /// `resend` asks for a new one, and skips it inside a signing window.
    /// For a signature, `phone` sends the code to a number not yet proven;
    /// the code then proves it and confirms the signature with one SMS.
    func requestCode(_ purpose: SmsPurpose, invoiceID: UUID?, phone: String?,
                     resend: Bool) async throws -> SmsChallenge
    func confirm(_ purpose: SmsPurpose, code: String, invoiceID: UUID?) async throws -> SmsConfirmation
}

public extension SmsRepository {
    func requestCode(_ purpose: SmsPurpose, invoiceID: UUID?, phone: String?) async throws -> SmsChallenge {
        try await requestCode(purpose, invoiceID: invoiceID, phone: phone, resend: false)
    }
}

/// Mobile numbers as the server understands them (`normalise_mobile`), so the
/// app can tell a typo from a number before anything is sent.
public enum MobileNumber {
    /// E.164 for a French mobile however it is typed, or any international
    /// number given with its + prefix; nil otherwise.
    public static func e164(_ raw: String) -> String? {
        var v = raw.filter { !" .-()\u{00A0}".contains($0) }
        if v.hasPrefix("00") { v = "+" + v.dropFirst(2) }
        if v.count == 10, v.hasPrefix("06") || v.hasPrefix("07"), v.allSatisfy(\.isNumber) {
            v = "+33" + v.dropFirst()
        }
        if v.count == 11, v.hasPrefix("336") || v.hasPrefix("337"), v.allSatisfy(\.isNumber) {
            v = "+" + v
        }
        guard v.hasPrefix("+"), v.dropFirst().allSatisfy(\.isASCII), v.dropFirst().allSatisfy(\.isNumber)
        else { return nil }
        let digits = v.dropFirst()
        if digits.hasPrefix("33") {
            return digits.count == 11 && (digits.dropFirst(2).hasPrefix("6") || digits.dropFirst(2).hasPrefix("7"))
                ? v : nil
        }
        return (8...15).contains(digits.count) && !digits.hasPrefix("0") ? v : nil
    }

    /// A French number as it is written, in pairs: "06 12 34 56 78". Anything
    /// typed with a + is left as typed.
    public static func formatted(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("+") else { return raw }
        let digits = String(trimmed.filter { $0.isASCII && $0.isNumber }.prefix(10))
        guard digits.hasPrefix("0") else { return digits }
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && i % 2 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// Only the digits of a code, at most six: what a paste or the keyboard's
    /// one-time-code suggestion fills in.
    public static func code(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }
}

/// SMS for the demo and previews. The code is always the same, and is shown
/// on the code screen, since no SMS is ever sent.
public actor PreviewSmsRepository: SmsRepository {
    public static let demoCode = "123456"

    private let required: Bool
    private var verifiedPhone: String?
    private var attempts = 0
    private var pending: String?
    private var pendingPurpose: SmsPurpose?
    private var signingWindowEnds: Date?
    /// SMS "sent", to show in tests and previews how few there are.
    public private(set) var sent = 0

    public init(required: Bool = false, verifiedPhone: String? = nil) {
        self.required = required
        self.verifiedPhone = verifiedPhone
    }

    private func mask(_ e164: String) -> String {
        e164.hasPrefix("+33") && e164.count == 12
            ? "+33 \(e164.dropFirst(3).prefix(1)) •• •• •• \(e164.suffix(2))"
            : "\(e164.prefix(3)) •••• \(e164.suffix(2))"
    }

    public func status() async throws -> SmsStatus {
        SmsStatus(smsRequired: required, phoneVerified: verifiedPhone != nil,
                  maskedPhone: verifiedPhone.map(mask))
    }

    public func requestCode(_ purpose: SmsPurpose, invoiceID: UUID?, phone: String?,
                            resend: Bool) async throws -> SmsChallenge {
        let number: String
        switch purpose {
        case .signInvoice, .signContract:
            guard required else { return SmsChallenge(required: false) }
            if purpose == .signInvoice, let ends = signingWindowEnds, ends > .now, let verifiedPhone {
                return SmsChallenge(required: false, maskedPhone: mask(verifiedPhone), session: true)
            }
            if let phone {
                guard let typed = MobileNumber.e164(phone) else { throw SmsError.invalidNumber }
                number = typed
            } else if let verifiedPhone {
                number = verifiedPhone
            } else {
                throw SmsError.phoneNotVerified
            }
        case .verifyPhone:
            guard let typed = phone.flatMap(MobileNumber.e164) else { throw SmsError.invalidNumber }
            number = typed
        }
        if !resend, pending == number, pendingPurpose == purpose, attempts < 5 {
            return SmsChallenge(required: true, maskedPhone: mask(number),
                                expiresAt: .now.addingTimeInterval(600), reused: true)
        }
        attempts = 0
        pending = number
        pendingPurpose = purpose
        sent += 1
        return SmsChallenge(required: true, maskedPhone: mask(number),
                            expiresAt: .now.addingTimeInterval(600))
    }

    public func confirm(_ purpose: SmsPurpose, code: String, invoiceID: UUID?) async throws -> SmsConfirmation {
        guard pending != nil else {
            return SmsConfirmation(ok: false, reason: "expired", message: "Ce code a expiré. Demandez-en un nouveau.")
        }
        guard attempts < 5 else {
            return SmsConfirmation(ok: false, reason: "locked", message: "Trop d'essais. Demandez un nouveau code.")
        }
        guard MobileNumber.code(code) == Self.demoCode else {
            attempts += 1
            return attempts >= 5
                ? SmsConfirmation(ok: false, reason: "locked", message: "Trop d'essais. Demandez un nouveau code.")
                : SmsConfirmation(ok: false, reason: "wrong", message: "Code incorrect.", attemptsLeft: 5 - attempts)
        }
        if let pending { verifiedPhone = pending }   // either purpose proves the number
        if purpose == .signInvoice { signingWindowEnds = .now.addingTimeInterval(600) }
        pending = nil
        pendingPurpose = nil
        return SmsConfirmation(ok: true, maskedPhone: verifiedPhone.map(mask))
    }
}

public enum SmsError: LocalizedError, Equatable {
    case phoneNotVerified
    case invalidNumber

    public var errorDescription: String? {
        switch self {
        case .phoneNotVerified: "Indiquez votre numéro de mobile."
        case .invalidNumber: "Ce numéro de mobile n'est pas valide."
        }
    }
}
