// ChappieErrorTests.swift
// ChappieCoreTests
//
// Юнит-тесты для ChappieError — централизованного перечисления ошибок приложения.
//
// ЗАЧЕМ ТЕСТИРОВАТЬ ОШИБКИ:
// ChappieError — это публичный контракт: сообщения об ошибках видит пользователь.
// Если кто-то переименует кейс или изменит текст errorDescription,
// тест сразу покажет что контракт нарушен.
//
// ПРИНЦИП: Проверяем что errorDescription не nil и содержит ключевые слова.
// Не проверяем точный текст — это хрупко. Проверяем смысл.
//
// ЭТОТ ФАЙЛ СОЗДАН ДЛЯ ПРОВЕРКИ ПАЙПЛАЙНА build → run_tests (2025-07-11).

import Testing
import Foundation
@testable import ChappieCore

@Suite("ChappieError Tests")
struct ChappieErrorTests {

    // MARK: - Тесты errorDescription

    /// networkError возвращает описание содержащее переданное сообщение.
    @Test("networkError содержит переданное сообщение")
    func networkErrorDescription() {
        let error = ChappieError.networkError("соединение разорвано")
        let description = error.errorDescription ?? ""

        // Описание должно быть непустым и содержать переданный текст
        #expect(!description.isEmpty)
        #expect(description.contains("соединение разорвано"))
    }

    /// fileSystemError возвращает описание содержащее переданное сообщение.
    @Test("fileSystemError содержит переданное сообщение")
    func fileSystemErrorDescription() {
        let error = ChappieError.fileSystemError("файл не найден")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("файл не найден"))
    }

    /// parsingError возвращает описание содержащее переданное сообщение.
    @Test("parsingError содержит переданное сообщение")
    func parsingErrorDescription() {
        let error = ChappieError.parsingError("невалидный JSON")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("невалидный JSON"))
    }

    /// memoryError возвращает описание содержащее переданное сообщение.
    @Test("memoryError содержит переданное сообщение")
    func memoryErrorDescription() {
        let error = ChappieError.memoryError("база данных недоступна")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("база данных недоступна"))
    }

    /// aiContextLimitExceeded возвращает непустое описание.
    @Test("aiContextLimitExceeded возвращает непустое описание")
    func aiContextLimitExceededDescription() {
        let error = ChappieError.aiContextLimitExceeded
        let description = error.errorDescription ?? ""

        // Этот кейс без ассоциированного значения — просто проверяем что описание есть
        #expect(!description.isEmpty)
    }

    /// unknown возвращает описание содержащее переданное сообщение.
    @Test("unknown содержит переданное сообщение")
    func unknownErrorDescription() {
        let error = ChappieError.unknown("что-то пошло не так")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("что-то пошло не так"))
    }

    // MARK: - Тест Sendable

    /// ChappieError можно безопасно передавать между акторами (Sendable).
    @Test("ChappieError передаётся между акторами без ошибок (Sendable)")
    func chappieErrorIsSendable() async {
        // Этот тест компилируется только если ChappieError: Sendable
        let error = ChappieError.networkError("тест")

        let result = await Task.detached {
            // Передаём ошибку в другой actor-контекст
            return error.errorDescription ?? ""
        }.value

        #expect(!result.isEmpty)
    }

    // MARK: - Тест LocalizedError

    /// ChappieError соответствует LocalizedError — errorDescription не nil.
    @Test("Все кейсы ChappieError имеют непустой errorDescription")
    func allCasesHaveDescription() {
        // Перечисляем все кейсы вручную — enum не Iterable, но это небольшой список
        let errors: [ChappieError] = [
            .networkError("x"),
            .fileSystemError("x"),
            .parsingError("x"),
            .memoryError("x"),
            .aiContextLimitExceeded,
            .unknown("x")
        ]

        for error in errors {
            // Каждый кейс должен иметь непустое описание для пользователя
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty, "Кейс \(error) не имеет errorDescription")
        }
    }
}
