//
//  ChappieError.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Глобальный обработчик ошибок.
///
/// Централизованное перечисление всех возможных ошибок в приложении.
///
/// АРХИТЕКТУРНОЕ РЕШЕНИЕ — КЕЙС .cancelled (FIX-CANCELLED):
/// URLSession бросает URLError(.cancelled) когда Swift Task отменяется во время стриминга.
/// Это НЕ ошибка пользователя — это нормальное завершение задачи (например, пользователь
/// нажал кнопку "Стоп" или быстро отправил новое сообщение).
/// Отдельный кейс .cancelled позволяет ViewModel явно отличить отмену от реальной ошибки
/// и НЕ показывать "Упс, ошибка: cancelled" пользователю.
public enum ChappieError: LocalizedError, Sendable {
    case networkError(String)
    case fileSystemError(String)
    case parsingError(String)
    case memoryError(String)
    case aiContextLimitExceeded

    /// Задача была отменена (URLError.cancelled или CancellationError).
    ///
    /// КОГДА ВОЗНИКАЕТ:
    /// - Пользователь быстро нажимает отправить повторно → предыдущий Task отменяется
    /// - View пересоздаётся → Task деаллоцируется
    /// - URLSession отменяет запрос по внутренней причине
    ///
    /// КАК ОБРАБАТЫВАТЬ:
    /// ViewModel ловит этот кейс отдельно и тихо завершает работу без сообщения об ошибке.
    case cancelled

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
        case .cancelled:
            // Описание нужно для логов, но пользователю не показывается.
            return "Запрос отменён."
        case .unknown(let msg):
            return "Неизвестная ошибка: \(msg)"
        }
    }
}
