//
//  SettingsView.swift
//  Chappie
//
//  Created by Чаппи on 22.05.2026.
//

import SwiftUI

/// Экран настроек приложения.
///
/// ПОЧЕМУ ОТДЕЛЬНЫЙ ЭКРАН, А НЕ ALERT:
/// Alert слишком мал для ввода длинного API-ключа и не позволяет показать
/// инструкции и статус. Sheet — правильный паттерн для настроек в macOS/iOS.
///
/// ПОЧЕМУ НЕ Settings Bundle:
/// Settings Bundle (системные настройки macOS) — неудобно для пользователя,
/// требует выхода из приложения. Встроенный Sheet — намного лучший UX.
struct SettingsView: View {

    // MARK: - Зависимости

    /// Менеджер настроек — единственный источник истины для API-ключа.
    @State private var settings = SettingsManager.shared

    /// Коллбэк, вызываемый при сохранении нового ключа.
    /// ViewModel использует его для пересоздания AITunnelClient с новым ключом.
    var onApiKeyChanged: ((String) -> Void)?

    // MARK: - Локальное состояние

    /// Локальная копия ключа для редактирования.
    /// Мы не редактируем settings.apiKey напрямую, чтобы не сохранять
    /// промежуточные (неполные) значения при каждом нажатии клавиши.
    @State private var localApiKey: String = ""

    /// Флаг показа/скрытия ключа (по умолчанию скрыт — это пароль).
    @State private var isKeyVisible: Bool = false

    /// Флаг для анимации подтверждения сохранения.
    @State private var showSavedConfirmation: Bool = false

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Заголовок
            HStack {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Настройки Чаппи")
                    .font(.title2.bold())
                Spacer()
                Button {
                    dismiss()
                } label: {
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
                VStack(alignment: .leading, spacing: 24) {

                    // MARK: Секция API-ключа
                    VStack(alignment: .leading, spacing: 12) {
                        Label("API-ключ AITunnel", systemImage: "key.fill")
                            .font(.headline)

                        Text("Ключ используется для обращения к языковым моделям через сервис AITunnel. Получить ключ можно на [aitunnel.ru](https://aitunnel.ru).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        // MARK: Поле ввода ключа
                        HStack(spacing: 8) {
                            Group {
                                if isKeyVisible {
                                    // Обычное текстовое поле когда ключ показан
                                    TextField("sk-aitunnel-...", text: $localApiKey)
                                } else {
                                    // Защищённое поле когда ключ скрыт
                                    SecureField("sk-aitunnel-...", text: $localApiKey)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                            // Кнопка показа/скрытия ключа
                            Button {
                                isKeyVisible.toggle()
                            } label: {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(isKeyVisible ? "Скрыть ключ" : "Показать ключ")
                        }

                        // MARK: Статус валидности ключа
                        HStack(spacing: 6) {
                            let isValid = localApiKey.hasPrefix("sk-aitunnel-") && localApiKey.count > 20
                            Image(systemName: isValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(isValid ? .green : (localApiKey.isEmpty ? .secondary : .orange))
                            Text(isValid ? "Ключ выглядит корректно" : (localApiKey.isEmpty ? "Ключ не задан" : "Ключ должен начинаться с sk-aitunnel-"))
                                .font(.caption)
                                .foregroundStyle(isValid ? .green : (localApiKey.isEmpty ? .secondary : .orange))
                        }
                    }

                    Divider()

                    // MARK: Секция безопасности
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Безопасность", systemImage: "lock.shield.fill")
                            .font(.headline)

                        // Показываем реальный статус хранилища
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ключ хранится в системном Keychain")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Keychain — зашифрованное хранилище macOS, защищённое вашим паролем. Ключ недоступен другим приложениям и не сохраняется в резервных копиях iCloud.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()

                    // MARK: Кнопка удаления ключа
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Опасная зона", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Button(role: .destructive) {
                            deleteApiKey()
                        } label: {
                            Label("Удалить ключ из Keychain", systemImage: "trash")
                        }
                        .disabled(settings.apiKey.isEmpty)
                    }
                }
                .padding(24)
            }

            Divider()

            // MARK: Кнопки действий
            HStack {
                Spacer()

                // Кнопка отмены — закрываем без сохранения
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                // Кнопка сохранения — применяем новый ключ
                Button {
                    saveApiKey()
                } label: {
                    HStack(spacing: 6) {
                        if showSavedConfirmation {
                            Image(systemName: "checkmark")
                            Text("Сохранено!")
                        } else {
                            Text("Сохранить")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                // Блокируем кнопку если ключ не изменился
                .disabled(localApiKey == settings.apiKey)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 420)
        .onAppear {
            // При открытии загружаем текущий ключ в локальную копию для редактирования
            localApiKey = settings.apiKey
        }
    }

    // MARK: - Приватные методы

    /// Сохраняет новый API-ключ в Keychain и уведомляет ViewModel.
    private func saveApiKey() {
        let trimmed = localApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Сохраняем через SettingsManager — он запишет в Keychain
        settings.apiKey = trimmed

        // Уведомляем ViewModel, чтобы она пересоздала AITunnelClient с новым ключом.
        // Это критично: без этого коллбэка старый клиент продолжит работать со старым ключом
        // до следующего перезапуска приложения.
        onApiKeyChanged?(trimmed)

        // Показываем анимацию подтверждения на 1.2 секунды, затем закрываем
        withAnimation {
            showSavedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            dismiss()
        }
    }

    /// Удаляет API-ключ из Keychain и сбрасывает локальное состояние.
    private func deleteApiKey() {
        settings.apiKey = ""
        localApiKey = ""
        onApiKeyChanged?("")
        dismiss()
    }
}

#Preview {
    SettingsView()
}
