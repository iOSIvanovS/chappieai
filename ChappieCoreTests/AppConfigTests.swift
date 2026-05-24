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

    /// tokenBudget — бюджет токенов истории — должен быть разумным.
    ///
    /// ПОЧЕМУ tokenBudget, а не maxHistoryMessages:
    /// Мы перешли от подсчёта "количества сообщений" к подсчёту токенов.
    /// Это точнее — короткие сообщения не выбрасываются зря, длинные обрезаются агрессивнее.
    @Test("tokenBudget в разумном диапазоне [4000...100000]")
    func tokenBudgetIsReasonable() {
        let config = AppConfig.shared
        // Меньше 4000 токенов — контекст будет слишком маленьким для работы
        // Больше 100,000 — превысим контекстное окно модели и потратим лишние деньги
        #expect(config.tokenBudget >= 4_000)
        #expect(config.tokenBudget <= 100_000)
    }

    /// recentFullMessages — количество последних полных сообщений — должно быть разумным.
    @Test("recentFullMessages в разумном диапазоне [1...20]")
    func recentFullMessagesIsReasonable() {
        let config = AppConfig.shared
        // Меньше 1 — нет ни одного полного сообщения, только summary — теряем текущий контекст
        // Больше 20 — слишком много полных ответов с кодом, расходуем весь бюджет впустую
        #expect(config.recentFullMessages >= 1)
        #expect(config.recentFullMessages <= 20)
    }

    /// summaryThreshold — минимальный размер для суммаризации.
    @Test("summaryThreshold в разумном диапазоне [100...2000] токенов")
    func summaryThresholdIsReasonable() {
        let config = AppConfig.shared
        // Меньше 100 токенов — суммаризируем даже "да" и "вперёд!" — бессмысленно
        // Больше 2000 — суммаризируем только очень длинные ответы, теряем экономию
        #expect(config.summaryThreshold >= 100)
        #expect(config.summaryThreshold <= 2_000)
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

    /// recentFullMessages должен быть меньше tokenBudget в токенах.
    @Test("recentFullMessages логически согласован с tokenBudget")
    func recentFullMessagesConsistentWithTokenBudget() {
        let config = AppConfig.shared
        // Каждое "полное" сообщение может быть до summaryThreshold токенов.
        // Произведение не должно превышать весь бюджет — иначе summary бесполезны.
        let maxFullTokens = config.recentFullMessages * config.summaryThreshold * 2
        #expect(maxFullTokens <= config.tokenBudget * 2)
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
