// ChappieViewModel+License.swift
// Chappie
//
// License lifecycle: initialization, owner JWT activation, state observation.
// LicenseService runs as an actor in ChappieCore — all calls are async.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Bootstrap

    /// Called once from ChappieApp.onAppear after ModelContainer is connected.
    /// Runs LicenseService.initialize() and publishes the result to licenseState.
    func initializeLicense() {
        Task {
            await licenseService.initialize()
            await syncLicenseState()
        }
    }

    /// Sync actor state → @Observable property so SwiftUI re-renders.
    func syncLicenseState() async {
        let newState = await licenseService.state
        licenseState = newState
        print("[License] State: \(newState)")
    }

    // MARK: - Owner JWT Activation

    /// Verifies and stores the owner JWT. Returns true on success.
    /// UI calls this when user pastes their JWT token.
    @discardableResult
    func activateOwnerLicense(jwt: String) async -> Bool {
        let success = await licenseService.activateOwnerLicense(jwt: jwt)
        if success {
            await syncLicenseState()
        }
        return success
    }

    // MARK: - Paid License Activation

    /// Activates a paid license key against the backend.
    /// Throws LicenseError on failure.
    func activateLicense(key: String) async throws {
        _ = try await licenseService.activate(key: key)
        await syncLicenseState()
    }

    // MARK: - Convenience

    var isOwner: Bool {
        if case .owner = licenseState { return true }
        return false
    }

    var isLicensed: Bool {
        switch licenseState {
        case .owner, .active, .gracePeriod, .trial: return true
        default: return false
        }
    }
}
