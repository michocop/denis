import Foundation
import Security
import LocalAuthentication

/// Persists the refresh token in the Keychain so the app does not ask for a
/// password on every launch, and gates its reuse behind Face ID.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is deliberate: the token must
/// not ride an iCloud backup onto another device, and must be unreadable while
/// the phone is locked.
public struct SessionStore: Sendable {

    private let service: String
    private let account = "supabase.refresh_token"

    public init(service: String = "com.trinityenergie.energycourtage") {
        self.service = service
    }

    public func save(refreshToken: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(refreshToken.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func refreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    public enum KeychainError: Error { case status(OSStatus) }
}

/// Face ID / Touch ID gate.
///
/// This protects a session that is already on the device; it is not an
/// authentication factor of its own, so a device without biometrics simply
/// falls through to the passcode, and one with neither proceeds — the session
/// was already earned with a password.
public enum BiometricGate {
    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public static func authenticate(
        reason: String = "Déverrouiller votre espace apporteur"
    ) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: reason)) ?? false
    }
}
