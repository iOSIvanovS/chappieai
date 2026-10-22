// OnboardingView.swift
// Chappie
//
// First-launch onboarding screen. Also shown on demand via AppState.
//
// FLOW:
// Step 1: User name (optional) — saved directly to global memory via viewModel.saveUserName()
//         Also offers "Restore from Backup" — skips the entire wizard by importing a
//         previously exported .chappiebackup file (machine migration shortcut).
// Step 2: First AI provider setup — uses CatalogPickerSheet in onboarding mode.
//         If at least one provider already exists, user can skip this step.
//         CatalogPickerSheet → AddProviderSheet (catalog or custom).
//         Multi-key input is available in AddProviderSheet onboarding mode.
//
// TRIGGER:
// Shown when AppState.shared.shouldShowOnboarding == true.
// Completion calls AppState.shared.completeOnboarding() → sets UserDefaults flag.
// Debug: AppState.shared.debugForceOnboarding = true forces re-show without clearing data.
//
// MERGE RULES (safe re-run — no data is deleted):
// - Provider: if a provider with the same website URL already exists → skip adding,
//   update only its display name.
// - Key: if a key with the same value already exists for this provider → skip adding,
//   update only its display name.
// - Models: add only models not already present for this provider (by name).
//   Models belong to a specific provider — same model name for different providers
//   is allowed and treated as distinct.

import SwiftUI
import ChappieCore

// MARK: - OnboardingView

struct OnboardingView: View {

    // MARK: - Dependencies

    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var step: OnboardingStep = .welcome
    @State private var userName: String = ""
    @State private var showAddProvider: Bool = false
    @State private var showBackupImport: Bool = false

    private enum OnboardingStep {
        case welcome
        case provider
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Image("Chappie")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.3)

            VStack(spacing: 0) {
                Spacer()

                switch step {
                case .welcome:
                    welcomeStep
                case .provider:
                    providerStep
                }

                Spacer()
            }
            .padding(40)
        }
        // Catalog picker in onboarding mode — shared remote service for session cache
        .sheet(isPresented: $showAddProvider) {
            CatalogPickerSheet(
                providerStore: viewModel.providerStore,
                remoteService: viewModel.providersRemoteService,
                isOnboarding: true,
                onSaved: {
                    showAddProvider = false
                    viewModel.reloadProviders()
                    AppState.shared.completeOnboarding()
                },
                onCancel: {
                    showAddProvider = false
                }
            )
        }
        // Restore from a backup file instead of walking the wizard — e.g. right after
        // a machine migration. Jumps straight past onboarding on success.
        .sheet(isPresented: $showBackupImport) {
            BackupImportSheet(viewModel: viewModel) {
                showBackupImport = false
                AppState.shared.completeOnboarding()
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image("Chappie")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 2))

                Text("onboarding.greeting")
                    .font(.largeTitle.bold())

                Text("onboarding.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("onboarding.name_label", systemImage: "person.fill")
                    .font(.headline)

                TextField("onboarding.name_placeholder", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16))
                    .frame(maxWidth: 320)

                Text("onboarding.name_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.saveUserName(userName)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    step = .provider
                }
            } label: {
                HStack(spacing: 8) {
                    Text("onboarding.continue")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return)

            // Escape hatch for machine migration — skips the whole wizard if a backup exists.
            Button {
                showBackupImport = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text("onboarding.restore_from_backup")
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 480)
    }

    // MARK: - Step 2: Provider Setup

    private var providerStep: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)

                Text("onboarding.provider_title")
                    .font(.largeTitle.bold())

                Text("onboarding.provider_subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showAddProvider = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("onboarding.add_provider")
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Skip is available only when at least one provider is already configured
            if !viewModel.providers.isEmpty {
                Button {
                    AppState.shared.completeOnboarding()
                } label: {
                    Text("onboarding.skip")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    step = .welcome
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                    Text("onboarding.back")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 480)
    }
}
