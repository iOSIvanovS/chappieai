// AppConfigTests.swift
// ChappieCoreTests
//
// Юнит-тесты для AppConfig — централизованной конфигурации приложения.
//
// ЗАЧЕМ ТЕСТИРОВАТЬ КОНФИГ:
// AppConfig — единственный источник истины для всех "магических чисел".
// Если кто-то случайно поставит maxOrchestratorSteps = 0 или requestTimeoutSeconds = 1,
// это сломает всё приложение неочевидным образом. Тесты защищают от таких ошибок.
//
// ПРИНЦИП: Проверяем не конкретные значения, а разумные диапазоны.
// Это позволяет менять параметры тюнинга без поломки тестов.

import Testing
import Foundation
@testable import ChappieCore

@Suite("AppConfig Tests")
struct AppConfigTests {

    // MARK: - Тесты дефолтных значений

    /// Singleton shared возвращает один и тот же экземпляр.
    @Test("AppConfig.shared — один экземпляр (singleton)")
    func sharedIsSingleton() {
        let config1 = AppConfig.shared
        let config2 = AppConfig.shared
        // Структуры сравниваются по значению — должны быть равны
        #expect(config1 == config2)
    }

    /// maxOrchestratorSteps должен быть в разумном диапазоне.
    @Test("maxOrchestratorSteps в разумном диапазоне [10...1000]")
    func maxOrchestratorStepsIsReasonable() {
        let config = AppConfig.shared
        // Меньше 10 — агент не успеет выполнить сложную задачу
        // Больше 1000 — риск бесконечного цикла и огромных расходов
        #expect(config.maxOrchestratorSteps >= 10)
        #expect(config.maxOrchestratorSteps <= 1000)
    }

    /// maxHistoryMessages должен быть в разумном диапазоне.
    @Test("maxHistoryMessages в разумном диапазоне [5...100]")
    func maxHistoryMessagesIsReasonable() {
        let config = AppConfig.shared
        // Меньше 5 — контекст будет слишком маленьким
        // Больше 100 — риск превышения контекстного окна модели
        #expect(config.maxHistoryMessages >= 5)
        #expect(config.maxHistoryMessages <= 100)
    }

    /// requestTimeoutSeconds должен быть достаточным для сложных задач.
    @Test("requestTimeoutSeconds достаточен для сложных задач (>= 60 сек)")
    func requestTimeoutIsAdequate() {
        let config = AppConfig.shared
        // Меньше 60 секунд — будут таймауты при обычной работе
        // Больше 600 секунд (10 минут) — пользователь будет ждать вечно
        #expect(config.requestTimeoutSeconds >= 60)
        #expect(config.requestTimeoutSeconds <= 600)
    }

    /// connectionTimeoutSeconds должен быть разумным.
    @Test("connectionTimeoutSeconds в разумном диапазоне [10...60]")
    func connectionTimeoutIsReasonable() {
        let config = AppConfig.shared
        // Меньше 10 секунд — слишком агрессивно для нестабильного соединения
        // Больше 60 секунд — пользователь слишком долго ждёт при недоступном сервере
        #expect(config.connectionTimeoutSeconds >= 10)
        #expect(config.connectionTimeoutSeconds <= 60)
    }

    /// connectionTimeout должен быть меньше requestTimeout.
    @Test("connectionTimeout < requestTimeout (логическое ограничение)")
    func connectionTimeoutLessThanRequestTimeout() {
        let config = AppConfig.shared
        // Логическое ограничение: нет смысла ждать установки соединения
        // дольше, чем весь запрос
        #expect(config.connectionTimeoutSeconds < config.requestTimeoutSeconds)
    }

    // MARK: - Тест Codable

    /// AppConfig проходит roundtrip encode → decode без потерь.
    @Test("AppConfig Codable roundtrip")
    func appConfigCodableRoundtrip() throws {
        let original = AppConfig.shared
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded == original)
    }

    // MARK: - Тест Sendable

    /// AppConfig можно безопасно передавать между акторами (Sendable).
    @Test("AppConfig передаётся между акторами без ошибок (Sendable)")
    func appConfigIsSendable() async {
        // Этот тест компилируется только если AppConfig: Sendable
        // Если Sendable убрать — будет ошибка компиляции, а не рантайм
        let config = AppConfig.shared

        // Передаём в другой actor-контекст
        let result = await Task.detached {
            return config.maxOrchestratorSteps
        }.value

        #expect(result == AppConfig.shared.maxOrchestratorSteps)
    }
}
