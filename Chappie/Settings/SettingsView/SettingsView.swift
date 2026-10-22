import SwiftUI
import ChappieCore
import Sparkle

// MARK: - SettingsView

struct SettingsView: View {

    var viewModel: ChappieViewModel

    @State var userName: String = ""
    @State var showProviders: Bool = false
    @State var showMemory: Bool = false
    @State var nameSaved: Bool = false
    @State var showOnboardingConfirm: Bool = false
    @State var showEULAConfirm: Bool = false
    @State var showLicenseActivation: Bool = false
    @State var showBackupExport: Bool = false
    @State var showBackupImport: Bool = false

    @Environment(\.sparkleUpdater) var sparkleUpdater
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    nameSection
                    Divider()
                    providersSection
                    Divider()
                    memorySection
                    Divider()
                    updatesSection
                    Divider()
                    onboardingSection
                    Divider()
                    securitySection
                    Divider()
                    backupSection
                    Divider()
                    licenseSection
                }
                .padding(24)
            }
            Divider()
            footer
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
        .sheet(isPresented: $showBackupExport) {
            BackupExportSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showBackupImport) {
            BackupImportSheet(viewModel: viewModel)
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

    // MARK: - Header / Footer

    private var header: some View {
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
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("settings.close") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

#Preview {
    Text("SettingsView preview")
}
