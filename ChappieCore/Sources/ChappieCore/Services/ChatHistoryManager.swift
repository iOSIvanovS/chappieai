//
//  ChatHistoryManager.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Менеджер для сохранения и загрузки истории чата в локальный JSON-файл.
/// Это решает проблему хранения больших массивов данных в UserDefaults (Tech Debt #2).
public final class ChatHistoryManager: Sendable {
    public static let shared = ChatHistoryManager()
    
    private let fileURL: URL
    
    private init() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        fileURL = documentsDirectory.appendingPathComponent("chappie_chat_history.json")
    }
    
    /// Загружает историю из файла (используя Generic, чтобы не зависеть от конкретной модели ChatMessage из UI-слоя)
    public func loadMessages<T: Codable>() -> [T] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            let messages = try JSONDecoder().decode([T].self, from: data)
            return messages
        } catch {
            print("Failed to decode chat history: \(error)")
            return []
        }
    }
    
    /// Сохраняет историю в файл
    public func saveMessages<T: Codable>(_ messages: [T]) {
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save chat history: \(error)")
        }
    }
}
