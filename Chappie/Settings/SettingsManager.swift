//
//  SettingsManager.swift
//  Chappie
//
//  Created by Чаппи on 22.05.2026.
//

import Foundation
import SwiftUI

/// Централизованный менеджер настроек приложения.
///
/// ПОЧЕМУ ОТДЕЛЬНЫЙ КЛАСС:
/// Раньше API-ключ был захардкожен прямо в ChappieViewModel — это создавало риск
/// утечки ключа в git-историю и делало смену ключа невозможной без перекомпиляции.
/// Теперь ключ живёт исключительно в Keychain и управляется через этот класс.
///
/// ПОЧЕМУ KEYCHAIN:
/// Keychain — зашифрованное системное хранилище macOS, защищённое паролем
/// пользователя. В отличие от UserDefaults (открытый plist-файл), Keychain
/// гарантирует что API-ключ не может быть прочитан другими процессами.
///
/// ПОЧЕМУ @Observable:
/// SettingsManager наблюдается из UI (SettingsView), поэтому нам нужна реактивность.
/// При изменении ключа SettingsView мгновенно перерисовывается.
@Observable
@MainActor
final class SettingsManager {

    // MARK: - Синглтон

    /// Глобальная точка доступа к настройкам.
    /// Используется из ChappieViewModel и SettingsView.
    static let shared = SettingsManager()

    // MARK: - Ключи UserDefaults (только для немиграционных флагов)

    private enum UDKeys {
        /// Флаг: была ли выполнена миграция ключа из UserDefaults в Keychain.
        /// Нужен однократно при обновлении с предыдущей версии приложения.
        static let migrationDone = "keychainMigrationDone"
        /// Старый ключ UserDefaults — нужен только для миграции.
        static let legacyApiKey = "aiTunnelApiKey"
    }

    // MARK: - Свойства

    /// Текущий API-ключ AITunnel.
    ///
    /// При установке нового значения автоматически сохраняется в Keychain.
    /// Пустая строка означает "ключ не задан".
    var apiKey: String {
        didSet {
            // Сохраняем в Keychain при каждом изменении.
            // Trim убирает случайные пробелы, которые пользователь мог вставить при копировании.
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Если ключ пустой — удаляем запись из Keychain полностью
                KeychainManager.delete()
            } else {
                KeychainManager.save(trimmed)
            }
        }
    }

    /// Флаг: задан ли ключ и выглядит ли он правдоподобно.
    /// Используется в UI для показа предупреждений и блокировки чата.
    var isApiKeyValid: Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Минимальная проверка: ключ AITunnel начинается с "sk-aitunnel-" и имеет достаточную длину
        return trimmed.hasPrefix("sk-aitunnel-") && trimmed.count > 20
    }

    // MARK: - Инициализация

    private init() {
        // Шаг 1: Проверяем нужна ли миграция с UserDefaults на Keychain.
        // Это нужно для пользователей, которые уже сохранили ключ в старой версии.
        let migrationDone = UserDefaults.standard.bool(forKey: UDKeys.migrationDone)
        if !migrationDone {
            SettingsManager.migrateFromUserDefaults()
        }

        // Шаг 2: Загружаем ключ из Keychain.
        // Если ключа нет — возвращаем пустую строку, чтобы UI показал поле для ввода.
        self.apiKey = KeychainManager.load() ?? ""
    }

    // MARK: - Приватные методы

    /// Выполняет однократную миграцию API-ключа из UserDefaults в Keychain.
    ///
    /// ПОЧЕМУ НУЖНА МИГРАЦИЯ:
    /// Предыдущая версия хранила ключ в UserDefaults. Чтобы пользователь
    /// не потерял свой ключ при обновлении, мы читаем старое значение,
    /// переносим в Keychain и удаляем из UserDefaults.
    private static func migrateFromUserDefaults() {
        if let legacyKey = UserDefaults.standard.string(forKey: UDKeys.legacyApiKey),
           !legacyKey.isEmpty {
            // Переносим ключ в Keychain
            KeychainManager.save(legacyKey)
            // Удаляем из UserDefaults — больше не нужен
            UserDefaults.standard.removeObject(forKey: UDKeys.legacyApiKey)
        }
        // Помечаем миграцию как выполненную чтобы не повторять при каждом запуске
        UserDefaults.standard.set(true, forKey: UDKeys.migrationDone)
    }
}
