import Foundation
import CryptoKit
import Security
import IOKit

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

// MARK: - LicenseService

/// Actor owning all license logic: hardware_id, Keychain storage,
/// trial/activation/validation flows.
public actor LicenseService {

    private let backendURL = "https://api.chappieai.ru"

    // Published state — observed by ChappieViewModel
    public private(set) var state: LicenseState = .loading

    public init() {}

    // MARK: - Public API

    /// Call on every app launch. Determines current license state.
    public func initialize() async {
        let hardwareId = getHardwareId()

        // 1. Stored license key — try to validate online
        if let licenseKey = KeychainHelper.read(key: .key), !licenseKey.isEmpty {
            let plan = LicensePlan(rawValue: KeychainHelper.read(key: .plan) ?? "") ?? .trial
            do {
                let result = try await validateOnline(key: licenseKey, hardwareId: hardwareId)
                if result.isActive {
                    KeychainHelper.write(key: .lastValidatedAt, value: ISO8601DateFormatter().string(from: Date()))
                    let expiresAt = result.expiresAt.flatMap { parseDate($0) }
                    if plan == .trial {
                        let days = daysRemaining(from: expiresAt)
                        state = days > 0 ? .trial(daysRemaining: days) : .expired(plan: .trial)
                    } else {
                        state = .active(plan: plan, expiresAt: expiresAt)
                    }
                } else {
                    state = .expired(plan: plan)
                }
            } catch LicenseError.licenseInvalid {
                state = .expired(plan: plan)
            } catch {
                // Network failure — grace period
                state = resolveGracePeriodState(plan: plan)
            }
            return
        }

        // 2. No license at all — register trial automatically
        await registerTrialIfNeeded(hardwareId: hardwareId)
    }

    /// Register trial on first launch. Idempotent — safe to call multiple times.
    public func registerTrialIfNeeded(hardwareId: String) async {
        do {
            let result = try await registerTrialOnline(hardwareId: hardwareId)
            KeychainHelper.write(key: .key, value: result.key)
            KeychainHelper.write(key: .plan, value: LicensePlan.trial.rawValue)
            if let exp = result.expiresAt { KeychainHelper.write(key: .expiresAt, value: exp) }
            KeychainHelper.write(key: .lastValidatedAt, value: ISO8601DateFormatter().string(from: Date()))

            let expiresAt = result.expiresAt.flatMap { parseDate($0) }
            let days = daysRemaining(from: expiresAt)

            if result.isActive && days > 0 {
                state = .trial(daysRemaining: days)
            } else {
                state = .expired(plan: .trial)
            }
        } catch {
            // Can't reach server on first launch — no license yet
            state = .noLicense
        }
    }

    /// Activate a paid license key. Returns updated LicenseState.
    public func activate(key: String) async throws -> LicenseState {
        let hardwareId = getHardwareId()
        let result = try await activateOnline(key: key, hardwareId: hardwareId)

        let plan = LicensePlan(rawValue: result.plan) ?? .starter
        let expiresAt = result.expiresAt.flatMap { parseDate($0) }

        KeychainHelper.write(key: .key, value: key)
        KeychainHelper.write(key: .plan, value: plan.rawValue)
        if let exp = result.expiresAt { KeychainHelper.write(key: .expiresAt, value: exp) }
        KeychainHelper.write(key: .lastValidatedAt, value: ISO8601DateFormatter().string(from: Date()))

        let newState = LicenseState.active(plan: plan, expiresAt: expiresAt)
        state = newState
        return newState
    }

    /// Returns the real Mac serial number via IOKit.
    /// Never changes, never stored in Keychain — always read directly from hardware.
    public func getHardwareId() -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0 else { return fallbackHardwareId() }

        let key = "IOPlatformSerialNumber" as CFString
        guard let serial = IORegistryEntryCreateCFProperty(
            platformExpert, key, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String, !serial.isEmpty else {
            return fallbackHardwareId()
        }
        return serial
    }

    /// Fallback: UUID stored in Keychain. Used only if IOKit fails (VM, rare edge case).
    private func fallbackHardwareId() -> String {
        if let existing = KeychainHelper.read(key: .hardwareId) { return existing }
        let new = UUID().uuidString
        KeychainHelper.write(key: .hardwareId, value: new)
        return new
    }

    // MARK: - Date Parsing

    /// Tolerant ISO8601 parser — handles both "2026-06-15T22:11:31Z" (new backend)
    /// and legacy "2026-06-15T22:11:31.034478" (old rows without timezone suffix).
    private func parseDate(_ string: String) -> Date? {
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = strict.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.timeZone = TimeZone(identifier: "UTC")
        legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let date = legacy.date(from: string) { return date }

        legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return legacy.date(from: string)
    }

    // MARK: - Helpers

    private func daysRemaining(from date: Date?) -> Int {
        guard let date else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0)
    }

    // MARK: - Grace Period

    private func resolveGracePeriodState(plan: LicensePlan) -> LicenseState {
        guard let lastValidatedStr = KeychainHelper.read(key: .lastValidatedAt),
              let lastValidated = ISO8601DateFormatter().date(from: lastValidatedStr)
        else {
            return .expired(plan: plan)
        }

        let daysSince = Calendar.current.dateComponents([.day], from: lastValidated, to: Date()).day ?? 999
        let graceDaysLeft = max(0, 7 - daysSince)

        return graceDaysLeft > 0 ? .gracePeriod(daysRemaining: graceDaysLeft) : .expired(plan: plan)
    }

    // MARK: - Network Calls

    private struct TrialResponse: Codable {
        let key: String
        let plan: String
        let expires_at: String?
        let is_active: Bool

        var expiresAt: String? { expires_at }
        var isActive: Bool { is_active }
    }

    private struct ValidateRequest: Codable {
        let license_key: String
        let hardware_id: String
    }

    private struct ValidateResponse: Codable {
        let is_active: Bool
        let plan: String?
        let expires_at: String?

        var isActive: Bool { is_active }
        var expiresAt: String? { expires_at }
    }

    private struct ActivateRequest: Codable {
        let license_key: String
        let hardware_id: String
    }

    private struct ActivateResponse: Codable {
        let key: String
        let plan: String
        let expires_at: String?
        let hardware_id: String?

        var expiresAt: String? { expires_at }
    }

    private func registerTrialOnline(hardwareId: String) async throws -> TrialResponse {
        let url = URL(string: "\(backendURL)/license/trial?hardware_id=\(hardwareId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LicenseError.networkError
        }
        return try JSONDecoder().decode(TrialResponse.self, from: data)
    }

    private func validateOnline(key: String, hardwareId: String) async throws -> ValidateResponse {
        let url = URL(string: "\(backendURL)/license/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ValidateRequest(license_key: key, hardware_id: hardwareId))
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseError.networkError }

        if http.statusCode == 403 || http.statusCode == 404 {
            throw LicenseError.licenseInvalid
        }
        guard http.statusCode == 200 else { throw LicenseError.networkError }
        return try JSONDecoder().decode(ValidateResponse.self, from: data)
    }

    private func activateOnline(key: String, hardwareId: String) async throws -> ActivateResponse {
        let url = URL(string: "\(backendURL)/license/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ActivateRequest(license_key: key, hardware_id: hardwareId))
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseError.networkError }

        switch http.statusCode {
        case 200: return try JSONDecoder().decode(ActivateResponse.self, from: data)
        case 403: throw LicenseError.licenseInvalid
        case 409: throw LicenseError.deviceLimitReached
        default:  throw LicenseError.networkError
        }
    }
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
