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
/// Теперь ключ живёт исключительно в UserDefaults и управляется через этот класс.
///
/// ПОЧЕМУ НЕ KEYCHAIN:
/// UserDefaults достаточно для macOS-приложения в разработке — данные хранятся
/// в защищённом контейнере приложения. Keychain — следующий шаг при выходе в продакшн.
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

    // MARK: - Ключи UserDefaults

    private enum Keys {
        static let apiKey = "aiTunnelApiKey"
    }

    // MARK: - Свойства

    /// Текущий API-ключ AITunnel.
    ///
    /// При установке нового значения автоматически сохраняется в UserDefaults.
    /// Пустая строка означает "ключ не задан".
    var apiKey: String {
        didSet {
            // Сохраняем в UserDefaults при каждом изменении.
            // Trim убирает случайные пробелы, которые пользователь мог вставить при копировании.
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: Keys.apiKey)
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
        // Загружаем сохранённый ключ из UserDefaults.
        // Если ключа нет — возвращаем пустую строку, чтобы UI показал поле для ввода.
        self.apiKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
    }
}
