// SettingsView.swift
// Chappie
//
// General application settings sheet.
//
// SECTIONS:
//   - User name: saved to global memory, used in system prompt.
//   - AI providers: shortcut to ProvidersSettingsView (the directory).
//   - Memory: shortcut to MemoryManagementView (per-thread history cleanup).
//   - Updates: Sparkle "Check for Updates" button + current app version.
//   - Onboarding: manual re-run trigger (calls AppState.resetOnboarding).
//   - EULA: manual re-show trigger (calls AppState.resetEULA) — for debug/review.
//   - Security: Keychain info.
//   - License: activate owner JWT or view current license state.
//
// NOTE: There is no "active provider" concept at the global level.
// Provider + key + model selection happens per-thread via the "Model" chip in the toolbar.
// ProvidersSettingsView is purely a directory — add/edit/delete, no selection.
//
// SPARKLE:
// SPUUpdater is received via @Environment(\.sparkleUpdater) — injected in ChappieApp.
// Sparkle must be explicitly imported here for checkForUpdates() and canCheckForUpdates.

import SwiftUI
import ChappieCore
import Sparkle

// MARK: - SettingsView

struct SettingsView: View {

    // MARK: - Dependencies

    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var userName: String = ""
    @State private var showProviders: Bool = false
    @State private var showMemory: Bool = false
    @State private var nameSaved: Bool = false
    @State private var showOnboardingConfirm: Bool = false
    @State private var showEULAConfirm: Bool = false
    @State private var showLicenseActivation: Bool = false

    // Sparkle updater passed via environment from ChappieApp.
    @Environment(\.sparkleUpdater) private var sparkleUpdater
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("settings.title")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {

                    // MARK: User Name
                    VStack(alignment: .leading, spacing: 12) {
                        Label("settings.name_section", systemImage: "person.fill")
                            .font(.headline)

                        Text("settings.name_hint")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            TextField("settings.name_placeholder", text: $userName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                                .onSubmit { saveName() }

                            Button {
                                saveName()
                            } label: {
                                HStack(spacing: 4) {
                                    if nameSaved {
                                        Image(systemName: "checkmark")
                                        Text("settings.name_saved")
                                    } else {
                                        Text("settings.name_save")
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(userName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Divider()

                    // MARK: AI Providers
                    VStack(alignment: .leading, spacing: 12) {
                        Label("settings.providers_section", systemImage: "cpu")
                            .font(.headline)

                        Text("settings.providers_hint")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            let count = viewModel.providers.count
                            if count > 0 {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(verbatim: "\(count) \(providersLabel(count))")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text("settings.providers_none")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.orange)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            }

                            Spacer()

                            Button {
                                showProviders = true
                            } label: {
                                Label("settings.providers_manage", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    // MARK: Memory Management
                    VStack(alignment: .leading, spacing: 12) {
                        Label("settings.memory_section", systemImage: "internaldrive")
                            .font(.headline)

                        Text("settings.memory_hint")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack {
                            let totalThreads = viewModel.threads.count
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(.blue)
                                Text(verbatim: "\(totalThreads) \(threadsLabel(totalThreads))")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                            Spacer()

                            Button {
                                showMemory = true
                            } label: {
                                Label("settings.memory_manage", systemImage: "trash.slash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    // MARK: Updates
                    VStack(alignment: .leading, spacing: 12) {
                        Label("settings.updates_section", systemImage: "arrow.down.circle")
                            .font(.headline)

                        HStack(spacing: 12) {
                            // Current app version badge
                            HStack(spacing: 6) {
                                Image(systemName: "app.badge.checkmark")
                                    .foregroundStyle(.secondary)
                                Text(String(format: String(localized: "settings.version"), appVersion))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                            Spacer()

                            Button {
                                sparkleUpdater?.checkForUpdates()
                            } label: {
                                Label("settings.check_updates", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(sparkleUpdater?.canCheckForUpdates == false)
                        }
                    }

                    Divider()

                    // MARK: Onboarding
                    VStack(alignment: .leading, spacing: 12) {
                        Label("settings.onboarding_section", systemImage: "wand.and.stars")
                            .font(.headline)

                        Text("settings.onboarding_hint")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button {
                                showOnboardingConfirm = true
                            } label: {
                                Label("settings.run_onboarding", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                showEULAConfirm = true
                            } label: {
                                Label("settings.show_eula", systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    // MARK: Security info
                    VStack(alignment: .leading, spacing: 8) {
                        Label("settings.security_section", systemImage: "lock.shield.fill")
                            .font(.headline)

                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.keychain_title")
                                    .font(.subheadline.weight(.medium))
                                Text("settings.keychain_hint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()

                    // MARK: License
                    VStack(alignment: .leading, spacing: 12) {
                        Label("license.section_title", systemImage: "key.fill")
                            .font(.headline)

                        HStack(spacing: 12) {
                            // Current license state badge
                            HStack(spacing: 6) {
                                Image(systemName: licenseIcon)
                                    .foregroundStyle(licenseColor)
                                Text(licenseLabel)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(licenseColor)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(licenseColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                            Spacer()

                            // Only show Activate button when not yet licensed
                            if !viewModel.isOwner {
                                Button {
                                    showLicenseActivation = true
                                } label: {
                                    Label("license.activate_button", systemImage: "key.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("settings.close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 640)
        .sheet(isPresented: $showProviders) {
            ProvidersSettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showMemory) {
            MemoryManagementView(viewModel: viewModel)
        }
        .sheet(isPresented: $showLicenseActivation) {
            LicenseActivationView(viewModel: viewModel)
        }
        .alert("settings.onboarding_confirm_title", isPresented: $showOnboardingConfirm) {
            Button("settings.onboarding_confirm_run") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    AppState.shared.resetOnboarding()
                }
            }
            Button("settings.onboarding_confirm_cancel", role: .cancel) {}
        } message: {
            Text("settings.onboarding_confirm_message")
        }
        .alert("settings.eula_confirm_title", isPresented: $showEULAConfirm) {
            Button("settings.eula_confirm_show") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    AppState.shared.resetEULA()
                }
            }
            Button("settings.eula_confirm_cancel", role: .cancel) {}
        } message: {
            Text("settings.eula_confirm_message")
        }
        .onAppear { loadCurrentName() }
    }

    // MARK: - License helpers

    private var licenseLabel: String {
        switch viewModel.licenseState {
        case .loading:     return String(localized: "license.state_checking")
        case .owner:       return String(localized: "license.state_owner")
        case .active:      return String(localized: "license.state_active")
        case .trial:       return String(localized: "license.state_trial")
        case .gracePeriod: return String(localized: "license.state_grace_period")
        case .expired:     return String(localized: "license.state_expired")
        case .noLicense:   return String(localized: "license.state_no_license")
        }
    }

    private var licenseIcon: String {
        switch viewModel.licenseState {
        case .owner:       return "crown.fill"
        case .active:      return "checkmark.seal.fill"
        case .trial:       return "clock.fill"
        case .gracePeriod: return "exclamationmark.triangle.fill"
        case .expired:     return "xmark.seal.fill"
        default:           return "key.slash.fill"
        }
    }

    private var licenseColor: Color {
        switch viewModel.licenseState {
        case .owner:       return .yellow
        case .active:      return .green
        case .trial:       return .blue
        case .gracePeriod: return .orange
        case .expired:     return .red
        default:           return .secondary
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // WHY: Russian pluralization has 3 forms (1/2-4/5+), English has 2 (1/other).
    // Using localized keys so each language can provide its own plural forms.
    private func providersLabel(_ count: Int) -> String {
        switch count {
        case 1: return String(localized: "settings.providers_one")
        case 2...4: return String(localized: "settings.providers_few")
        default: return String(localized: "settings.providers_many")
        }
    }

    private func threadsLabel(_ count: Int) -> String {
        switch count {
        case 1: return String(localized: "settings.threads_one")
        case 2...4: return String(localized: "settings.threads_few")
        default: return String(localized: "settings.threads_many")
        }
    }

    // MARK: - Actions

    private func saveName() {
        let trimmed = userName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.saveUserName(trimmed)
        withAnimation { nameSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { nameSaved = false }
        }
    }

    private func loadCurrentName() {
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

#Preview {
    Text("SettingsView preview")
}
