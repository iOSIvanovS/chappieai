//
//  MemoryManager.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation
import SwiftData

/// Модель данных для хранения в базе (SwiftData).
/// Что это: Запись о единице информации, которую запомнил ИИ.
/// Зачем: Позволяет сохранять данные между сессиями (долгосрочная память).
@Model
public final class MemoryRecord {
    @Attribute(.unique) public var key: String
    public var type: String // Например: "persona", "project_map", "rule", "fact"
    public var timestamp: Date
    public var jsonData: String // Сериализованные данные
    
    public init(key: String, type: String, timestamp: Date = Date(), jsonData: String) {
        self.key = key
        self.type = type
        self.timestamp = timestamp
        self.jsonData = jsonData
    }
}

/// Менеджер для работы с долгосрочной памятью (базой данных) ИИ.
/// Что это: Синглтон-обертка над SwiftData. Предоставляет CRUD-операции для MemoryRecord.
/// Зачем: Изолирует логику работы с БД. ИИ использует этот менеджер через инструменты (Tools)
/// для сохранения и извлечения контекста, правил и фактов.
@MainActor
public final class MemoryManager {
    /// Глобальная точка доступа к менеджеру памяти.
    public static let shared = MemoryManager()
    
    public let container: ModelContainer
    
    private init() {
        do {
            // Инициализируем контейнер SwiftData с сохранением на диск
            let config = ModelConfiguration(isStoredInMemoryOnly: false)
            container = try ModelContainer(for: MemoryRecord.self, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer for MemoryRecord: \(error)")
        }
    }
    
    public var context: ModelContext {
        container.mainContext
    }
    
    /// Сохраняет новую запись в память или обновляет существующую по ключу.
    /// - Parameters:
    ///   - key: Уникальный идентификатор записи.
    ///   - type: Категория информации (например, "rule").
    ///   - jsonString: Сами данные в формате JSON-строки.
    public func saveMemory(key: String, type: String, jsonString: String) {
        let fetchDescriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.key == key })
        
        do {
            let existingRecords = try context.fetch(fetchDescriptor)
            if let record = existingRecords.first {
                // Обновляем существующую запись
                record.type = type
                record.jsonData = jsonString
                record.timestamp = Date()
            } else {
                // Создаем новую запись
                let newRecord = MemoryRecord(key: key, type: type, jsonData: jsonString)
                context.insert(newRecord)
            }
            try context.save()
        } catch {
            print("Failed to save memory: \(error)")
        }
    }
    
    /// Читает запись из памяти по её ключу.
    /// - Parameter key: Уникальный идентификатор записи.
    /// - Returns: JSON-строка с данными или nil, если запись не найдена.
    public func readMemory(key: String) -> String? {
        let fetchDescriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.key == key })
        do {
            let records = try context.fetch(fetchDescriptor)
            return records.first?.jsonData
        } catch {
            print("Failed to read memory: \(error)")
            return nil
        }
    }
    
    /// Ищет все записи определенного типа.
    /// - Parameter type: Категория информации для поиска.
    /// - Returns: Словарь, где ключ — это ключ записи, а значение — JSON-строка с данными.
    public func searchMemory(type: String) -> [String: String] {
        let fetchDescriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.type == type })
        do {
            let records = try context.fetch(fetchDescriptor)
            var result: [String: String] = [:]
            for record in records {
                result[record.key] = record.jsonData
            }
            return result
        } catch {
            print("Failed to search memory by type: \(error)")
            return [:]
        }
    }
    
    /// Удаляет запись из памяти по ключу.
    /// - Parameter key: Уникальный ключ удаляемой записи.
    public func deleteMemory(key: String) {
        let fetchDescriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.key == key })
        do {
            let records = try context.fetch(fetchDescriptor)
            if let record = records.first {
                context.delete(record)
                try context.save()
            }
        } catch {
            print("Failed to delete memory: \(error)")
        }
    }
    
    /// Возвращает список всех ключей, сохраненных в памяти.
    /// Полезно для отладки или предоставления ИИ списка того, что он помнит.
    public func getAllKeys() -> [String] {
        let fetchDescriptor = FetchDescriptor<MemoryRecord>()
        do {
            let records = try context.fetch(fetchDescriptor)
            return records.map { $0.key }
        } catch {
            print("Failed to fetch all keys: \(error)")
            return []
        }
    }
}
