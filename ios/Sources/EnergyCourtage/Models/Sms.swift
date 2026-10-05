import Foundation

/// What a code sent by SMS is for. The server binds each code to one purpose
/// (and, for a signature, to one invoice), so a code cannot be reused.
public enum SmsPurpose: String, Sendable {
    case verifyPhone = "verify_phone"
    case signInvoice = "sign_invoice"
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
    /// False when no code is needed: the action goes ahead without one.
    public var required: Bool
    public var maskedPhone: String?
    public var expiresAt: Date?

    public init(required: Bool, maskedPhone: String? = nil, expiresAt: Date? = nil) {
        self.required = required
        self.maskedPhone = maskedPhone
        self.expiresAt = expiresAt
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
    func requestCode(_ purpose: SmsPurpose, invoiceID: UUID?, phone: String?) async throws -> SmsChallenge
    func confirm(_ purpose: SmsPurpose, code: String, invoiceID: UUID?) async throws -> SmsConfirmation
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

    public func requestCode(_ purpose: SmsPurpose, invoiceID: UUID?, phone: String?) async throws -> SmsChallenge {
        attempts = 0
        switch purpose {
        case .signInvoice:
            guard required else { return SmsChallenge(required: false) }
            guard let verifiedPhone else { throw SmsError.phoneNotVerified }
            return SmsChallenge(required: true, maskedPhone: mask(verifiedPhone),
                                expiresAt: .now.addingTimeInterval(600))
        case .verifyPhone:
            guard let number = phone.flatMap(MobileNumber.e164) else { throw SmsError.invalidNumber }
            pending = number
            return SmsChallenge(required: true, maskedPhone: mask(number),
                                expiresAt: .now.addingTimeInterval(600))
        }
    }

    private var pending: String?

    public func confirm(_ purpose: SmsPurpose, code: String, invoiceID: UUID?) async throws -> SmsConfirmation {
        guard attempts < 5 else {
            return SmsConfirmation(ok: false, reason: "locked", message: "Trop d'essais. Demandez un nouveau code.")
        }
        guard MobileNumber.code(code) == Self.demoCode else {
            attempts += 1
            return attempts >= 5
                ? SmsConfirmation(ok: false, reason: "locked", message: "Trop d'essais. Demandez un nouveau code.")
                : SmsConfirmation(ok: false, reason: "wrong", message: "Code incorrect.", attemptsLeft: 5 - attempts)
        }
        if purpose == .verifyPhone, let pending { verifiedPhone = pending }
        return SmsConfirmation(ok: true, maskedPhone: verifiedPhone.map(mask))
    }
}

public enum SmsError: LocalizedError, Equatable {
    case phoneNotVerified
    case invalidNumber

    public var errorDescription: String? {
        switch self {
        case .phoneNotVerified: "Vérifiez d'abord votre numéro de mobile."
        case .invalidNumber: "Ce numéro de mobile n'est pas valide."
        }
    }
}
