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
//
// NOTE: There is no "active provider" concept at the global level.
// Provider + key + model selection happens per-thread via the "Модель" chip in the toolbar.
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
                Text("Настройки")
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
                        Label("Ваше имя", systemImage: "person.fill")
                            .font(.headline)

                        Text("Чаппи будет обращаться к вам по имени в системном промпте.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            TextField("Имя", text: $userName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                                .onSubmit { saveName() }

                            Button {
                                saveName()
                            } label: {
                                HStack(spacing: 4) {
                                    if nameSaved {
                                        Image(systemName: "checkmark")
                                        Text("Сохранено")
                                    } else {
                                        Text("Сохранить")
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
                        Label("AI-провайдеры", systemImage: "cpu")
                            .font(.headline)

                        Text("Справочник провайдеров: ключи и модели для каждого из них. Выбор провайдера и модели происходит в чипсе «Модель» в тулбаре чата.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            let count = viewModel.providers.count
                            if count > 0 {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("\(count) \(providersLabel(count))")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Нет настроенных провайдеров")
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
                                Label("Управлять", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    // MARK: Memory Management
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Память", systemImage: "internaldrive")
                            .font(.headline)

                        Text("История сообщений хранится полностью. Здесь можно посмотреть объём каждого треда и удалить старые сообщения.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack {
                            let totalThreads = viewModel.threads.count
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(.blue)
                                Text("\(totalThreads) \(threadsLabel(totalThreads))")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                            Spacer()

                            Button {
                                showMemory = true
                            } label: {
                                Label("Управлять", systemImage: "trash.slash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    // MARK: Updates
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Обновления", systemImage: "arrow.down.circle")
                            .font(.headline)

                        HStack(spacing: 12) {
                            // Current app version badge
                            HStack(spacing: 6) {
                                Image(systemName: "app.badge.checkmark")
                                    .foregroundStyle(.secondary)
                                Text("Версия \(appVersion)")
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
                                Label("Проверить обновления", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(sparkleUpdater?.canCheckForUpdates == false)
                        }
                    }

                    Divider()

                    // MARK: Onboarding
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Онбординг", systemImage: "wand.and.stars")
                            .font(.headline)

                        Text("Повторно запустить мастер первоначальной настройки. Существующие данные не удаляются — провайдеры, ключи и модели только дополняются.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button {
                                showOnboardingConfirm = true
                            } label: {
                                Label("Запустить онбординг", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                showEULAConfirm = true
                            } label: {
                                Label("Показать соглашение", systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    // MARK: Security info
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Безопасность", systemImage: "lock.shield.fill")
                            .font(.headline)

                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("API-ключи хранятся в системном Keychain")
                                    .font(.subheadline.weight(.medium))
                                Text("Keychain — зашифрованное хранилище macOS, защищённое вашим паролем. Ключи недоступны другим приложениям.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 600)
        .sheet(isPresented: $showProviders) {
            ProvidersSettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showMemory) {
            MemoryManagementView(viewModel: viewModel)
        }
        .alert("Запустить онбординг?", isPresented: $showOnboardingConfirm) {
            Button("Запустить") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    AppState.shared.resetOnboarding()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Мастер настройки откроется снова. Ваши данные, треды и провайдеры сохранятся.")
        }
        .alert("Показать соглашение?", isPresented: $showEULAConfirm) {
            Button("Показать") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    AppState.shared.resetEULA()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Лицензионное соглашение откроется снова. Ваши данные не затронуты.")
        }
        .onAppear { loadCurrentName() }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func providersLabel(_ count: Int) -> String {
        switch count {
        case 1: return "провайдер"
        case 2...4: return "провайдера"
        default: return "провайдеров"
        }
    }

    private func threadsLabel(_ count: Int) -> String {
        switch count {
        case 1: return "тред"
        case 2...4: return "треда"
        default: return "тредов"
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
