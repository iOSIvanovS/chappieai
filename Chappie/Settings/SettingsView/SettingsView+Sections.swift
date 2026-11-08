import SwiftUI
import Sparkle

extension SettingsView {

    // MARK: - Support Section

    /// Donation page on lava.top; opened in the browser, the app itself handles no payment.
    private static let donationURL = URL(string: "https://app.lava.top/2651348976?tabId=donate")!

    var supportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.support_section", systemImage: "heart.fill")
                .font(.headline)

            Text("settings.support_hint")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Link(destination: Self.donationURL) {
                    Label("settings.support_action", systemImage: "heart")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Name Section

    var nameSection: some View {
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
    }

    // MARK: - Providers Section

    var providersSection: some View {
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

                Button { showProviders = true } label: {
                    Label("settings.providers_manage", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Memory Section

    var memorySection: some View {
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

                Button { showMemory = true } label: {
                    Label("settings.memory_manage", systemImage: "trash.slash")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Updates Section

    var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.updates_section", systemImage: "arrow.down.circle")
                .font(.headline)

            HStack(spacing: 12) {
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
    }

    // MARK: - Onboarding Section

    var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.onboarding_section", systemImage: "wand.and.stars")
                .font(.headline)

            Text("settings.onboarding_hint")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button { showOnboardingConfirm = true } label: {
                    Label("settings.run_onboarding", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button { showEULAConfirm = true } label: {
                    Label("settings.show_eula", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Security Section

    var securitySection: some View {
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
    }

    // MARK: - Backup Section

    var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.backup_section", systemImage: "square.and.arrow.up.on.square")
                .font(.headline)

            Text("settings.backup_hint")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Spacer()
                Button { showBackupImport = true } label: {
                    Label("settings.backup_import_action", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                Button { showBackupExport = true } label: {
                    Label("settings.backup_export_action", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
