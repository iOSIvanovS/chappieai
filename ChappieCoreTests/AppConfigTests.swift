// AppConfigTests.swift
// ChappieCoreTests
//
// Unit tests for AppConfig — centralized application configuration.
//
// WHY TEST CONFIG:
// AppConfig is the single source of truth for all "magic numbers".
// If someone accidentally sets maxOrchestratorSteps = 0 or requestTimeoutSeconds = 1,
// the entire app breaks in non-obvious ways. Tests guard against such errors.
//
// PRINCIPLE: Test reasonable ranges, not specific values.
// This allows tuning parameters without breaking tests.

import Testing
import Foundation
@testable import ChappieCore

@Suite("AppConfig Tests")
struct AppConfigTests {

    // MARK: - Default value tests (AppConfig.shared)

    @Test("AppConfig.shared — один экземпляр (singleton)")
    func sharedIsSingleton() {
        let config1 = AppConfig.shared
        let config2 = AppConfig.shared
        #expect(config1 == config2)
    }

    @Test("maxOrchestratorSteps в разумном диапазоне [10...1000]")
    func maxOrchestratorStepsIsReasonable() {
        let config = AppConfig.shared
        #expect(config.maxOrchestratorSteps >= 10)
        #expect(config.maxOrchestratorSteps <= 1000)
    }

    @Test("maxMessagesInContext в разумном диапазоне [100...1000]")
    func maxMessagesInContextIsReasonable() {
        let config = AppConfig.shared
        #expect(config.maxMessagesInContext >= 100)
        #expect(config.maxMessagesInContext <= 1000)
    }

    @Test("requestTimeoutSeconds достаточен для сложных задач (>= 60 сек)")
    func requestTimeoutIsAdequate() {
        let config = AppConfig.shared
        #expect(config.requestTimeoutSeconds >= 60)
        #expect(config.requestTimeoutSeconds <= 600)
    }

    @Test("connectionTimeoutSeconds в разумном диапазоне [10...60]")
    func connectionTimeoutIsReasonable() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds >= 10)
        #expect(config.connectionTimeoutSeconds <= 60)
    }

    @Test("connectionTimeout < requestTimeout (логическое ограничение)")
    func connectionTimeoutLessThanRequestTimeout() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds < config.requestTimeoutSeconds)
    }

    // MARK: - Dynamic config tests

    /// tokenBudget is computed as maxMessagesInContext × 500.
    @Test("tokenBudget = maxMessagesInContext × 500")
    func tokenBudgetFormula() {
        let testCases: [(messages: Int, expectedBudget: Int)] = [
            (100, 50_000),
            (200, 100_000),
            (300, 150_000),
            (500, 250_000),
            (1000, 500_000)
        ]

        for testCase in testCases {
            let config = AppConfig(maxMessagesInContext: testCase.messages)
            #expect(
                config.tokenBudget == testCase.expectedBudget,
                "For \(testCase.messages) messages expected budget \(testCase.expectedBudget), got \(config.tokenBudget)"
            )
        }
    }

    /// Values outside 100...1000 are clamped automatically.
    @Test("Clamping: значения вне диапазона 100...1000 зажимаются")
    func clampingOutOfRange() {
        // Too small → clamped to 100
        let tooSmall = AppConfig(maxMessagesInContext: 3)
        #expect(tooSmall.maxMessagesInContext == 100)
        #expect(tooSmall.tokenBudget == 50_000)

        // Too large → clamped to 1000
        let tooBig = AppConfig(maxMessagesInContext: 9999)
        #expect(tooBig.maxMessagesInContext == 1000)
        #expect(tooBig.tokenBudget == 500_000)

        // Boundary values — not clamped
        let minValid = AppConfig(maxMessagesInContext: 100)
        #expect(minValid.maxMessagesInContext == 100)

        let maxValid = AppConfig(maxMessagesInContext: 1000)
        #expect(maxValid.maxMessagesInContext == 1000)
    }

    /// Default config (shared) has tokenBudget = 300 × 500 = 150,000.
    @Test("AppConfig.shared: tokenBudget = 150,000 (300 сообщений × 500)")
    func sharedTokenBudget() {
        let config = AppConfig.shared
        #expect(config.maxMessagesInContext == 300)
        #expect(config.tokenBudget == 150_000)
    }

    @Test("AppConfig(settings:) создаётся из ThreadSettings корректно")
    func configFromThreadSettings() {
        let settings = ThreadSettings(maxMessagesInContext: 500)
        let config = AppConfig(settings: settings)

        #expect(config.maxMessagesInContext == 500)
        #expect(config.tokenBudget == 250_000)
    }

    // MARK: - Codable tests

    @Test("AppConfig Codable roundtrip")
    func appConfigCodableRoundtrip() throws {
        let original = AppConfig.shared
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("AppConfig(maxMessagesInContext:) Codable roundtrip")
    func dynamicConfigCodableRoundtrip() throws {
        let original = AppConfig(maxMessagesInContext: 400)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded == original)
        #expect(decoded.maxMessagesInContext == 400)
        #expect(decoded.tokenBudget == 400 * 500)
    }

    // MARK: - Sendable test

    @Test("AppConfig передаётся между акторами без ошибок (Sendable)")
    func appConfigIsSendable() async {
        let config = AppConfig(maxMessagesInContext: 300)

        let result = await Task.detached {
            return config.tokenBudget
        }.value

        #expect(result == 300 * 500)
    }
}
