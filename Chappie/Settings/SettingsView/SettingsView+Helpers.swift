import SwiftUI
import ChappieCore

extension SettingsView {

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
