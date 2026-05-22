//
//  ChappieError.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Глобальный обработчик ошибок (Tech Debt #6)
/// Централизованное перечисление всех возможных ошибок в приложении.
public enum ChappieError: LocalizedError, Sendable {
    case networkError(String)
    case fileSystemError(String)
    case parsingError(String)
    case memoryError(String)
    case aiContextLimitExceeded
    case unknown(String)
    
    public var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return "Сетевая ошибка: \(msg)"
        case .fileSystemError(let msg):
            return "Ошибка файловой системы: \(msg)"
        case .parsingError(let msg):
            return "Ошибка парсинга данных: \(msg)"
        case .memoryError(let msg):
            return "Ошибка базы данных памяти: \(msg)"
        case .aiContextLimitExceeded:
            return "Превышен лимит контекста ИИ. Пожалуйста, очистите историю или уменьшите размер файлов."
        case .unknown(let msg):
            return "Неизвестная ошибка: \(msg)"
        }
    }
}
