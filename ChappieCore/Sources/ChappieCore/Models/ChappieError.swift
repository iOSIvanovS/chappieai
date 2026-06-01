// ChappieError.swift
// ChappieCore

import Foundation

/// Centralized error enum for all ChappieCore failures.
public enum ChappieError: LocalizedError, Sendable {
    case networkError(String)
    case fileSystemError(String)
    case parsingError(String)
    case memoryError(String)
    case aiContextLimitExceeded

    /// URLSession throws URLError(.cancelled) when a Swift Task is cancelled mid-stream.
    /// This is NOT a user-facing error — ViewModel catches it and silently stops.
    case cancelled

    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let msg):       return "Сетевая ошибка: \(msg)"
        case .fileSystemError(let msg):    return "Ошибка файловой системы: \(msg)"
        case .parsingError(let msg):       return "Ошибка парсинга данных: \(msg)"
        case .memoryError(let msg):        return "Ошибка базы данных памяти: \(msg)"
        case .aiContextLimitExceeded:      return "Превышен лимит контекста ИИ. Пожалуйста, очистите историю или уменьшите размер файлов."
        case .cancelled:                   return "Запрос отменён."
        case .unknown(let msg):            return "Неизвестная ошибка: \(msg)"
        }
    }
}
