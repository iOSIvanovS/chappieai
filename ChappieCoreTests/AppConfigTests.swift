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
//
// ИСТОРИЯ ИЗМЕНЕНИЙ:
// - IT-02 (REFACTOR-THREADS): Добавлены тесты для динамического AppConfig.
//   Новый init(maxMessagesInContext:) + формула tokenBudget = maxMessages × 500.
//   Тест clamping: значения вне диапазона 10...100 зажимаются автоматически.
// - maxHistoryMessages → maxMessagesInContext (поле было переименовано при рефакторинге)

import Testing
import Foundation
@testable import ChappieCore

@Suite("AppConfig Tests")
struct AppConfigTests {

    // MARK: - Тесты дефолтных значений (AppConfig.shared)

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

    /// maxMessagesInContext — жёсткий лимит на количество сообщений в контекстном окне.
    @Test("maxMessagesInContext в разумном диапазоне [5...100]")
    func maxMessagesInContextIsReasonable() {
        let config = AppConfig.shared
        // Меньше 5 — контекст будет слишком маленьким для связного диалога
        // Больше 100 — риск превышения контекстного окна модели
        #expect(config.maxMessagesInContext >= 5)
        #expect(config.maxMessagesInContext <= 100)
    }

    /// requestTimeoutSeconds должен быть достаточным для сложных задач.
    @Test("requestTimeoutSeconds достаточен для сложных задач (>= 60 сек)")
    func requestTimeoutIsAdequate() {
        let config = AppConfig.shared
        #expect(config.requestTimeoutSeconds >= 60)
        #expect(config.requestTimeoutSeconds <= 600)
    }

    /// connectionTimeoutSeconds должен быть разумным.
    @Test("connectionTimeoutSeconds в разумном диапазоне [10...60]")
    func connectionTimeoutIsReasonable() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds >= 10)
        #expect(config.connectionTimeoutSeconds <= 60)
    }

    /// connectionTimeout должен быть меньше requestTimeout.
    @Test("connectionTimeout < requestTimeout (логическое ограничение)")
    func connectionTimeoutLessThanRequestTimeout() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds < config.requestTimeoutSeconds)
    }

    // MARK: - Тесты динамического конфига (IT-02)

    /// tokenBudget вычисляется как maxMessagesInContext × 500.
    ///
    /// ФОРМУЛА: tokenBudget = maxMessagesInContext × 500
    /// Это ключевой инвариант IT-02 — нарушение формулы сломает всю систему контекста.
    @Test("tokenBudget = maxMessagesInContext × 500 (формула IT-02)")
    func tokenBudgetFormula() {
        // Проверяем формулу для нескольких значений
        let testCases: [(messages: Int, expectedBudget: Int)] = [
            (10, 5_000),
            (20, 10_000),
            (50, 25_000),
            (100, 50_000)
        ]

        for testCase in testCases {
            let config = AppConfig(maxMessagesInContext: testCase.messages)
            #expect(
                config.tokenBudget == testCase.expectedBudget,
                "Для \(testCase.messages) сообщений ожидаем бюджет \(testCase.expectedBudget), получили \(config.tokenBudget)"
            )
        }
    }

    /// Значения вне диапазона 10...100 зажимаются автоматически.
    ///
    /// ЗАЧЕМ CLAMPING:
    /// JSON из SwiftData может содержать некорректные данные (повреждение, старая схема).
    /// Зажимание в init() защищает от аварийных ситуаций: tokenBudget < 0 или > 50,000.
    @Test("Clamping: значения вне диапазона 10...100 зажимаются")
    func clampingOutOfRange() {
        // Слишком маленькое значение → зажимается до 10
        let tooSmall = AppConfig(maxMessagesInContext: 3)
        #expect(tooSmall.maxMessagesInContext == 10)
        #expect(tooSmall.tokenBudget == 5_000)

        // Слишком большое значение → зажимается до 100
        let tooBig = AppConfig(maxMessagesInContext: 999)
        #expect(tooBig.maxMessagesInContext == 100)
        #expect(tooBig.tokenBudget == 50_000)

        // Граничные значения — не зажимаются
        let minValid = AppConfig(maxMessagesInContext: 10)
        #expect(minValid.maxMessagesInContext == 10)

        let maxValid = AppConfig(maxMessagesInContext: 100)
        #expect(maxValid.maxMessagesInContext == 100)
    }

    /// Дефолтный конфиг (shared) имеет tokenBudget = 20 × 500 = 10,000.
    @Test("AppConfig.shared: tokenBudget = 10,000 (20 сообщений × 500)")
    func sharedTokenBudget() {
        let config = AppConfig.shared
        #expect(config.maxMessagesInContext == 20)
        #expect(config.tokenBudget == 10_000)
    }

    /// AppConfig(settings:) создаёт конфиг из ThreadSettings корректно.
    @Test("AppConfig(settings:) создаётся из ThreadSettings корректно")
    func configFromThreadSettings() {
        let settings = ThreadSettings(maxMessagesInContext: 50)
        let config = AppConfig(settings: settings)

        #expect(config.maxMessagesInContext == 50)
        #expect(config.tokenBudget == 25_000)
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

    /// Динамический конфиг также проходит Codable roundtrip.
    @Test("AppConfig(maxMessagesInContext:) Codable roundtrip")
    func dynamicConfigCodableRoundtrip() throws {
        let original = AppConfig(maxMessagesInContext: 42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded == original)
        #expect(decoded.maxMessagesInContext == 42)
        #expect(decoded.tokenBudget == 42 * 500)
    }

    // MARK: - Тест Sendable

    /// AppConfig можно безопасно передавать между акторами (Sendable).
    @Test("AppConfig передаётся между акторами без ошибок (Sendable)")
    func appConfigIsSendable() async {
        // Этот тест компилируется только если AppConfig: Sendable
        // Если Sendable убрать — будет ошибка компиляции, а не рантайм
        let config = AppConfig(maxMessagesInContext: 30)

        // Передаём в другой actor-контекст
        let result = await Task.detached {
            return config.tokenBudget
        }.value

        #expect(result == 30 * 500)
    }
}
