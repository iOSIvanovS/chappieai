import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Bootstrap

    /// Called once from setModelContainer() after stores are connected.
    func initializeLicense() {
        Task {
            await licenseService.initialize()
            await syncLicenseState()
        }
    }

    /// Sync actor state → @Observable property so SwiftUI re-renders.
    /// Also pushes the new state to ToolExecutionService for plan-based access control.
    /// When Starter plan is detected — downgrades all projects to Advisor role.
    func syncLicenseState() async {
        let newState = await licenseService.state
        licenseState = newState
        print("[License] State: \(newState)")

        if let ts = toolService {
            await ts.setLicenseState(newState)
        }

        // Starter plan forbids Executor role — downgrade all projects silently.
        if case .active(let plan, _) = newState, plan == .starter {
            if let pStore = projectStore {
                try? await pStore.downgradeAllProjectsToAdvisor()
                if let thread = activeThread {
                    await loadProjectsForThread(thread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                }
            }
        }
    }

    // MARK: - Paid License Activation

    func activateLicense(key: String) async throws {
        _ = try await licenseService.activate(key: key)
        await syncLicenseState()
    }

    // MARK: - Access Checks

    var isLicensed: Bool {
        switch licenseState {
        case .active, .gracePeriod, .trial: return true
        default: return false
        }
    }

    /// True if the current plan allows full Executor tools (not Starter).
    var canExecuteTools: Bool {
        switch licenseState {
        case .trial: return true
        case .gracePeriod: return true
        case .active(let plan, _): return plan != .starter
        default: return false
        }
    }

    /// True if sending messages is allowed at all.
    var canSendMessages: Bool {
        switch licenseState {
        case .loading: return false
        case .noLicense: return false
        case .expired: return false
        default: return true
        }
    }

    /// True if the paywall sheet should be shown instead of the main UI.
    var shouldShowPaywall: Bool {
        switch licenseState {
        case .noLicense, .expired: return true
        default: return false
        }
    }
}
