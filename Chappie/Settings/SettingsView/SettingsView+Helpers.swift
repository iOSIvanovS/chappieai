import SwiftUI
import ChappieCore

extension SettingsView {

    // MARK: - License Helpers

    var licenseBadgeText: String {
        let status = licenseLabel
        if let plan = licensePlanName {
            return "\(status) · \(plan)"
        }
        return status
    }

    var licensePlanName: String? {
        switch viewModel.licenseState {
        case .active(let plan, _):
            switch plan {
            case .starter: return "Starter"
            case .pro:     return "Pro"
            case .team:    return "Team"
            default:       return nil
            }
        case .expired(let plan):
            switch plan {
            case .starter: return "Starter"
            case .pro:     return "Pro"
            case .team:    return "Team"
            default:       return nil
            }
        default:
            return nil
        }
    }

    var licenseLabel: String {
        switch viewModel.licenseState {
        case .loading:     return String(localized: "license.state_checking")
        case .active:      return String(localized: "license.state_active")
        case .trial:       return String(localized: "license.state_trial")
        case .gracePeriod: return String(localized: "license.state_grace_period")
        case .expired:     return String(localized: "license.state_expired")
        case .noLicense:   return String(localized: "license.state_no_license")
        }
    }

    var licenseIcon: String {
        switch viewModel.licenseState {
        case .active:      return "checkmark.seal.fill"
        case .trial:       return "clock.fill"
        case .gracePeriod: return "exclamationmark.triangle.fill"
        case .expired:     return "xmark.seal.fill"
        default:           return "key.slash.fill"
        }
    }

    var licenseColor: Color {
        switch viewModel.licenseState {
        case .active:      return .green
        case .trial:       return .blue
        case .gracePeriod: return .orange
        case .expired:     return .red
        default:           return .secondary
        }
    }

    // WHY: Active users see "Manage Plan" (upgrade path), others see "Activate".
    var isActiveLicense: Bool {
        if case .active = viewModel.licenseState { return true }
        return false
    }

    var licenseButtonLabel: String {
        isActiveLicense
            ? String(localized: "license.manage_plan_button")
            : String(localized: "license.activate_button")
    }

    var licenseButtonIcon: String {
        isActiveLicense ? "arrow.up.circle" : "key.badge.plus"
    }

    // MARK: - General Helpers

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    func providersLabel(_ count: Int) -> String {
        switch count {
        case 1: return String(localized: "settings.providers_one")
        case 2...4: return String(localized: "settings.providers_few")
        default: return String(localized: "settings.providers_many")
        }
    }

    func threadsLabel(_ count: Int) -> String {
        switch count {
        case 1: return String(localized: "settings.threads_one")
        case 2...4: return String(localized: "settings.threads_few")
        default: return String(localized: "settings.threads_many")
        }
    }

    // MARK: - Actions

    func saveName() {
        let trimmed = userName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.saveUserName(trimmed)
        withAnimation { nameSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { nameSaved = false }
        }
    }

    func loadCurrentName() {
        guard viewModel.providerStore != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loadCurrentName() }
            return
        }
        Task {
            let name = await viewModel.loadUserName()
            if let name, !name.isEmpty {
                userName = name
            }
        }
    }
}
