// MigrationService.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Сервис одноразовой миграции данных из legacy-файлов в SwiftData (REFACTOR-THREADS IT-04).
//
// ЧТО МИГРИРУЕТСЯ:
// 1. chat_history.json → ThreadEntity "Основной" (первый тред с историей)
// 2. ~/Documents/Chappie/semantic.json → MemoryEntity scope="global"
//
// ИДЕМПОТЕНТНОСТЬ:
// Миграция выполняется ТОЛЬКО ОДИН РАЗ. Флаг "migration_v1_done" в UserDefaults
// гарантирует что при следующих запусках migrate() ничего не делает.
// Это критически важно: повторная миграция создаст дублирующийся тред.
//
// БЕЗОПАСНОСТЬ ДАННЫХ:
// Старые файлы НЕ удаляются. Они остаются как backup на случай если что-то
// пошло не так. Пользователь может удалить их вручную позже.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — GENERIC ДЛЯ ChatMessage:
// ChatMessage определён в Chappie (UI-таргет). MigrationService в ChappieCore
// не должен знать о нём. Поэтому migrate() принимает Generic-параметр T: Codable
// для типа сообщений — аналогично ChatHistoryManager и ThreadStore.
// UI-слой (ChappieViewModel) вызывает migrate<ChatMessage>(...).
//
// ПОРЯДОК ВЫЗОВА:
// ChappieViewModel.setModelContainer() → migrate() вызывается после инициализации
// всех сервисов. Это гарантирует что ThreadStore и MemoryStore уже готовы.

import Foundation
import SwiftData

// MARK: - MigrationService

/// Сервис одноразовой миграции legacy-данных в SwiftData.
///
/// ПОЧЕМУ ACTOR:
/// Миграция работает с SwiftData (через ThreadStore и MemoryStore) и с файловой системой.
/// Actor гарантирует что migrate() не будет вызван параллельно из нескольких мест.
public actor MigrationService {

    // MARK: - Константы

    /// Ключ UserDefaults для флага завершённой миграции.
    ///
    /// ПОЧЕМУ UserDefaults, А НЕ SwiftData:
    /// Флаг должен быть доступен ДО инициализации SwiftData.
    /// UserDefaults — самое простое и надёжное решение для булевых флагов запуска.
    private static let migrationFlagKey = "migration_v1_done"

    /// Название первого треда, создаваемого при миграции.
    private static let defaultThreadTitle = "Основной"

    // MARK: - Зависимости

    private let threadStore: ThreadStore
    private let memoryStore: MemoryStore
    private let fileManager = FileManager.default

    // MARK: - Инициализация

    /// Создаёт MigrationService с необходимыми сторами.
    ///
    /// - Parameters:
    ///   - threadStore: Актор для работы с тредами в SwiftData
    ///   - memoryStore: Актор для работы с памятью в SwiftData
    public init(threadStore: ThreadStore, memoryStore: MemoryStore) {
        self.threadStore = threadStore
        self.memoryStore = memoryStore
    }

    // MARK: - Публичный API

    /// Выполняет миграцию legacy-данных в SwiftData.
    ///
    /// ИДЕМПОТЕНТНОСТЬ:
    /// Проверяет флаг UserDefaults перед запуском. Если миграция уже выполнена — возвращает false.
    ///
    /// GENERIC T: Codable:
    /// Тип сообщений передаётся как параметр — ChappieCore не знает о ChatMessage.
    /// UI-слой вызывает: await migrationService.migrate(messageType: ChatMessage.self, ...)
    ///
    /// - Parameters:
    ///   - messageType: Тип для десериализации сообщений (например ChatMessage.self)
    ///   - chatHistoryURL: URL файла chat_history.json
    ///   - semanticMemoryURL: URL файла semantic.json (legacy)
    /// - Returns: true если миграция была выполнена, false если уже была выполнена ранее
    public func migrate<T: Codable>(
        messageType: T.Type,
        chatHistoryURL: URL,
        semanticMemoryURL: URL
    ) async -> Bool {
        // Проверяем флаг — если уже мигрировали, ничего не делаем
        guard !UserDefaults.standard.bool(forKey: Self.migrationFlagKey) else {
            print("[MigrationService] ✅ Миграция уже выполнена, пропускаем")
            return false
        }

        print("[MigrationService] 🚀 Начало миграции legacy-данных в SwiftData...")

        // ШАГ 1: Мигрируем историю чата
        await migrateChatHistory(messageType: messageType, from: chatHistoryURL)

        // ШАГ 2: Мигрируем семантическую память
        await migrateSemanticMemory(from: semanticMemoryURL)

        // ШАГ 3: Ставим флаг — миграция завершена
        // ВАЖНО: Флаг ставим ПОСЛЕ успешного завершения обоих шагов.
        // Если приложение упадёт в середине — при следующем запуске миграция повторится.
        // Это безопасно: ThreadStore.createThread() создаст второй тред "Основной",
        // но это лучше чем потерять данные.
        UserDefaults.standard.set(true, forKey: Self.migrationFlagKey)

        print("[MigrationService] ✅ Миграция завершена успешно")
        return true
    }

    // MARK: - Сброс флага (для тестирования и отладки)

    /// Сбрасывает флаг миграции — следующий вызов migrate() выполнит миграцию заново.
    ///
    /// ТОЛЬКО ДЛЯ ОТЛАДКИ И ТЕСТОВ. В продакшне не вызывать.
    public func resetMigrationFlag() {
        UserDefaults.standard.removeObject(forKey: Self.migrationFlagKey)
        print("[MigrationService] ⚠️ Флаг миграции сброшен (только для отладки)")
    }

    /// Проверяет был ли уже выполнен процесс миграции.
    public var isMigrationDone: Bool {
        UserDefaults.standard.bool(forKey: Self.migrationFlagKey)
    }

    // MARK: - Приватные методы миграции

    /// Мигрирует историю чата из chat_history.json в новый тред SwiftData.
    ///
    /// ЛОГИКА:
    /// 1. Читаем JSON-файл и декодируем как [T] (Generic тип сообщений)
    /// 2. Создаём тред "Основной" в ThreadStore
    /// 3. Сохраняем сообщения в тред через ThreadStore.saveMessages()
    ///
    /// ЕСЛИ ФАЙЛ НЕ СУЩЕСТВУЕТ:
    /// Создаём пустой тред "Основной" — это первый запуск приложения.
    /// Пользователь увидит чистый чат.
    ///
    /// - Parameters:
    ///   - messageType: Generic тип для десериализации
    ///   - url: URL файла chat_history.json
    private func migrateChatHistory<T: Codable>(messageType: T.Type, from url: URL) async {
        print("[MigrationService] 📨 Миграция истории чата из \(url.lastPathComponent)...")

        // Загружаем сообщения из файла
        let messages: [T]
        if fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([T].self, from: data) {
            messages = decoded
            print("[MigrationService] 📨 Загружено \(messages.count) сообщений из chat_history.json")
        } else {
            // Файла нет или он повреждён — создаём пустой тред
            messages = []
            print("[MigrationService] ℹ️ chat_history.json не найден или повреждён, создаём пустой тред")
        }

        // Создаём тред "Основной" в SwiftData
        do {
            let threadId = try await threadStore.createThread(
                title: Self.defaultThreadTitle,
                settings: ThreadSettings()
            )

            // Сохраняем сообщения в тред (если они есть)
            if !messages.isEmpty {
                try await threadStore.saveMessages(messages, toThreadId: threadId)
                print("[MigrationService] ✅ История чата перенесена в тред '\(Self.defaultThreadTitle)' (id: \(threadId))")
            } else {
                print("[MigrationService] ✅ Создан пустой тред '\(Self.defaultThreadTitle)' (id: \(threadId))")
            }
        } catch {
            print("[MigrationService] ❌ Ошибка создания треда: \(error)")
        }
    }

    /// Мигрирует семантическую память из semantic.json в SwiftData MemoryEntity.
    ///
    /// ЛОГИКА:
    /// 1. Читаем ~/Documents/Chappie/semantic.json
    /// 2. Декодируем как [String: LegacyMemoryRecord]
    /// 3. Конвертируем в [MemoryEntry]
    /// 4. Сохраняем в MemoryStore с scope="global"
    ///
    /// ЕСЛИ ФАЙЛ НЕ СУЩЕСТВУЕТ:
    /// Просто пропускаем — нет legacy-памяти для миграции.
    ///
    /// - Parameter url: URL файла semantic.json
    private func migrateSemanticMemory(from url: URL) async {
        guard fileManager.fileExists(atPath: url.path) else {
            print("[MigrationService] ℹ️ semantic.json не найден, пропускаем миграцию памяти")
            return
        }

        guard let data = try? Data(contentsOf: url),
              let storage = try? JSONDecoder().decode([String: LegacyMemoryRecord].self, from: data),
              !storage.isEmpty else {
            print("[MigrationService] ℹ️ semantic.json пуст или повреждён, пропускаем")
            return
        }

        print("[MigrationService] 🧠 Миграция \(storage.count) записей памяти из semantic.json...")

        // Конвертируем LegacyMemoryRecord → MemoryEntry
        let entries: [MemoryEntry] = storage.map { key, record in
            MemoryEntry(
                key: key,
                type: record.type,
                jsonString: record.data
            )
        }

        // Сохраняем все записи в SwiftData с scope="global"
        do {
            try await memoryStore.importEntries(entries, intoScope: "global")
            print("[MigrationService] ✅ \(entries.count) записей памяти перенесено в SwiftData (scope=global)")
        } catch {
            print("[MigrationService] ❌ Ошибка миграции памяти: \(error)")
        }
    }
}

// MARK: - LegacyMemoryRecord

/// Структура записи из legacy semantic.json.
///
/// ПОЧЕМУ ЗДЕСЬ, А НЕ В MemoryManager:
/// MemoryManager.MemoryRecord — приватная деталь реализации MemoryManager.
/// Для MigrationService нам нужна публичная Codable-структура для десериализации файла.
/// Дублирование минимально — это временный тип только для миграции.
///
/// ПОСЛЕ ЗАВЕРШЕНИЯ РЕФАКТОРИНГА:
/// Этот тип можно удалить когда semantic.json будет полностью упразднён.
private struct LegacyMemoryRecord: Codable {
    /// Тип записи (fact, rule, persona, project_map и т.д.)
    let type: String

    /// Временная метка создания записи.
    let timestamp: Date

    /// Содержимое записи в виде JSON-строки.
    let data: String

    // MARK: - Codable (кастомный декодер для совместимости)

    /// Кастомный декодер нужен потому что поле timestamp может отсутствовать
    /// в старых записях semantic.json (записанных до введения метки времени).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.data = try container.decode(String.self, forKey: .data)

        // timestamp опционален — старые записи могут его не иметь
        self.timestamp = (try? container.decode(Date.self, forKey: .timestamp)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(data, forKey: .data)
    }

    enum CodingKeys: String, CodingKey {
        case type, timestamp, data
    }
}
