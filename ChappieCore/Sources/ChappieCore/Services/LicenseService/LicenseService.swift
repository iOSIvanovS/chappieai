import Foundation
import IOKit

// MARK: - LicenseService

/// Actor owning all license logic: hardware_id, Keychain storage,
/// trial/activation/validation flows.
public actor LicenseService {

    let backendURL = "https://api.chappieai.ru"

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

    // MARK: - Helpers

    /// Fallback: UUID stored in Keychain. Used only if IOKit fails (VM, rare edge case).
    private func fallbackHardwareId() -> String {
        if let existing = KeychainHelper.read(key: .hardwareId) { return existing }
        let new = UUID().uuidString
        KeychainHelper.write(key: .hardwareId, value: new)
        return new
    }

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

    // MARK: - Date Parsing

    /// Tolerant ISO8601 parser — handles both "2026-06-15T22:11:31Z" (new backend)
    /// and legacy "2026-06-15T22:11:31.034478" (old rows without timezone suffix).
    func parseDate(_ string: String) -> Date? {
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
}
