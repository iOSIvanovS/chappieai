import Foundation
import Security

// MARK: - LicenseState

public enum LicenseState: Sendable, Equatable {
    case loading
    case trial(daysRemaining: Int)
    case active(plan: LicensePlan, expiresAt: Date?)
    case expired(plan: LicensePlan)
    case gracePeriod(daysRemaining: Int)
    case noLicense
}

// MARK: - LicensePlan

public enum LicensePlan: String, Sendable, Codable {
    case trial   = "trial"
    case starter = "starter"
    case pro     = "pro"
    case team    = "team"
}

// MARK: - LicenseError

public enum LicenseError: Error, LocalizedError {
    case networkError
    case licenseInvalid
    case deviceLimitReached

    public var errorDescription: String? {
        switch self {
        case .networkError:       return "Cannot reach license server"
        case .licenseInvalid:     return "License key is invalid or revoked"
        case .deviceLimitReached: return "Device limit reached for this license"
        }
    }
}

// MARK: - KeychainHelper

/// Minimal Keychain read/write for license data.
/// All keys prefixed with "license." — see licensing.md §5.
/// kSecAttrService scopes entries to this app. kSecAttrAccessibleAfterFirstUnlock
/// allows silent reads after boot without prompting the user for a password.
enum KeychainHelper {

    enum Key: String {
        case key             = "license.key"
        case plan            = "license.plan"
        case expiresAt       = "license.expires_at"
        case lastValidatedAt = "license.last_validated_at"
        case hardwareId      = "license.hardware_id"   // fallback only (VM/edge cases)
    }

    // Scopes all license entries to this app bundle — prevents cross-app collisions.
    private static let service: String = Bundle.main.bundleIdentifier ?? "ru.chappie"

    static func read(key: Key) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    @discardableResult
    static func write(key: Key, value: String) -> Bool {
        let data = Data(value.utf8)

        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData]      = data
            // AfterFirstUnlock: readable silently after first boot unlock, survives sleep/wake.
            newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(key: Key) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
