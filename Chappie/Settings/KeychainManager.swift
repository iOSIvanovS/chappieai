//
//  KeychainManager.swift
//  Chappie
//
//  Created by Чаппи on 22.05.2026.
//

import Foundation
import Security

/// Менеджер безопасного хранения секретов в системном Keychain macOS.
///
/// ПОЧЕМУ KEYCHAIN, А НЕ USERDEFAULTS:
/// UserDefaults хранит данные в открытом виде в plist-файле, доступном
/// любому процессу с правами пользователя. Keychain — зашифрованное системное
/// хранилище, защищённое паролем пользователя и Secure Enclave на Apple Silicon.
/// API-ключ — это секрет, который должен жить именно там.
///
/// ПОЧЕМУ STRUCT, А НЕ CLASS:
/// Все методы статические — нет состояния, нет экземпляров. Struct + static
/// — идиоматичный Swift для утилитарных сервисов без состояния.
struct KeychainManager {

    // MARK: - Ключи Keychain

    private enum Keys {
        /// Ключ для хранения API-токена AITunnel в Keychain.
        /// Используем bundle identifier чтобы избежать коллизий с другими приложениями.
        static let apiKey = "ru.chappie.aitunnel.apikey"
    }

    // MARK: - Публичный интерфейс

    /// Сохраняет строку в Keychain.
    ///
    /// - Parameters:
    ///   - value: Строка для сохранения (например, API-ключ).
    ///   - key: Уникальный ключ для идентификации записи.
    /// - Returns: `true` если сохранение прошло успешно.
    ///
    /// ПОЧЕМУ UPSERT:
    /// Keychain не позволяет добавить запись с уже существующим ключом — нужно
    /// сначала удалить старую, затем добавить новую. Это стандартный паттерн.
    @discardableResult
    static func save(_ value: String, for key: String = Keys.apiKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Формируем запрос для поиска существующей записи
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "ru.chappie"
        ]

        // Удаляем старую запись если существует (upsert-паттерн)
        SecItemDelete(query as CFDictionary)

        // Добавляем новую запись с данными
        var addQuery = query
        addQuery[kSecValueData as String] = data
        // kSecAttrAccessible — запись доступна только когда устройство разблокировано.
        // Это баланс между безопасностью и удобством: приложение не может читать ключ
        // в фоне когда Mac заблокирован, что правильно для секретов.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Загружает строку из Keychain по ключу.
    ///
    /// - Parameter key: Уникальный ключ записи.
    /// - Returns: Строка если запись найдена, `nil` если нет.
    static func load(for key: String = Keys.apiKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "ru.chappie",
            // Запрашиваем возврат данных записи
            kSecReturnData as String: true,
            // Возвращаем только один результат (самый свежий)
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Удаляет запись из Keychain.
    ///
    /// - Parameter key: Уникальный ключ записи для удаления.
    /// - Returns: `true` если удаление прошло успешно или запись не существовала.
    @discardableResult
    static func delete(for key: String = Keys.apiKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "ru.chappie"
        ]

        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound тоже считаем успехом — запись и так не существует
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Проверяет наличие записи в Keychain.
    ///
    /// - Parameter key: Уникальный ключ записи.
    /// - Returns: `true` если запись существует.
    static func exists(for key: String = Keys.apiKey) -> Bool {
        return load(for: key) != nil
    }
}
