// SettingsView.swift
// Chappie
//
// Application settings sheet.
// Contains: user name field (saved to global memory), AI providers shortcut.
//
// USER NAME:
//   On appear — reads current name from global SwiftData memory (key "user_name").
//   Parses JSON string {"name": "..."} to extract the value.
//   On save — calls viewModel.saveUserName() which writes back to global memory.
//
// NOTE: API key management moved to ProvidersSettingsView / AddProviderSheet.
// SettingsView is now a lightweight general settings panel.

import SwiftUI
import ChappieCore

// MARK: - SettingsView

struct SettingsView: View {

    // MARK: - Dependencies

    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var userName: String = ""
    @State private var showProviders: Bool = false
    @State private var nameSaved: Bool = false

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

                        Text("Управляйте провайдерами и списками моделей для каждого из них.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            if let provider = viewModel.activeProvider {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.displayName)
                                            .font(.system(size: 13, weight: .semibold))
                                        if let model = viewModel.activeModelName {
                                            Text(model)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Нет настроенного провайдера")
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
        .frame(width: 500, height: 440)
        .sheet(isPresented: $showProviders) {
            ProvidersSettingsView(viewModel: viewModel)
        }
        .onAppear { loadCurrentName() }
    }

    // MARK: - Actions

    private func saveName() {
        let trimmed = userName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.saveUserName(trimmed)
        withAnimation {
            nameSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { nameSaved = false }
        }
    }

    private func loadCurrentName() {
        // providerStore being non-nil means ModelContainer is connected and memoryStore is ready.
        // If not ready yet — retry after a short delay.
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
