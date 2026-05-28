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
//
// CHANGE HISTORY:
// - IT-02 (REFACTOR-THREADS): Added tests for dynamic AppConfig.
//   New init(maxMessagesInContext:) + formula tokenBudget = maxMessages × 500.
//   Clamping test: values outside 10...100 are clamped automatically.
// - maxHistoryMessages → maxMessagesInContext (field renamed during refactoring)
// - IT-11: Extended context range from 10...100 to 10...1000 (ThreadSettings).
//   Updated clamping test to reflect new upper bound.

import Testing
import Foundation
@testable import ChappieCore

@Suite("AppConfig Tests")
struct AppConfigTests {

    // MARK: - Default value tests (AppConfig.shared)

    /// Singleton shared returns the same instance.
    @Test("AppConfig.shared — один экземпляр (singleton)")
    func sharedIsSingleton() {
        let config1 = AppConfig.shared
        let config2 = AppConfig.shared
        // Structs compare by value — should be equal
        #expect(config1 == config2)
    }

    /// maxOrchestratorSteps should be in a reasonable range.
    @Test("maxOrchestratorSteps в разумном диапазоне [10...1000]")
    func maxOrchestratorStepsIsReasonable() {
        let config = AppConfig.shared
        #expect(config.maxOrchestratorSteps >= 10)
        #expect(config.maxOrchestratorSteps <= 1000)
    }

    /// maxMessagesInContext — hard limit on the number of messages in the context window.
    @Test("maxMessagesInContext в разумном диапазоне [5...1000]")
    func maxMessagesInContextIsReasonable() {
        let config = AppConfig.shared
        // Less than 5 — context too small for coherent dialogue
        // More than 1000 — risk of exceeding model context window
        #expect(config.maxMessagesInContext >= 5)
        #expect(config.maxMessagesInContext <= 1000)
    }

    /// requestTimeoutSeconds should be adequate for complex tasks.
    @Test("requestTimeoutSeconds достаточен для сложных задач (>= 60 сек)")
    func requestTimeoutIsAdequate() {
        let config = AppConfig.shared
        #expect(config.requestTimeoutSeconds >= 60)
        #expect(config.requestTimeoutSeconds <= 600)
    }

    /// connectionTimeoutSeconds should be reasonable.
    @Test("connectionTimeoutSeconds в разумном диапазоне [10...60]")
    func connectionTimeoutIsReasonable() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds >= 10)
        #expect(config.connectionTimeoutSeconds <= 60)
    }

    /// connectionTimeout must be less than requestTimeout.
    @Test("connectionTimeout < requestTimeout (логическое ограничение)")
    func connectionTimeoutLessThanRequestTimeout() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds < config.requestTimeoutSeconds)
    }

    // MARK: - Dynamic config tests (IT-02)

    /// tokenBudget is computed as maxMessagesInContext × 500.
    ///
    /// FORMULA: tokenBudget = maxMessagesInContext × 500
    /// This is the key IT-02 invariant — breaking the formula breaks the entire context system.
    @Test("tokenBudget = maxMessagesInContext × 500 (формула IT-02)")
    func tokenBudgetFormula() {
        let testCases: [(messages: Int, expectedBudget: Int)] = [
            (10, 5_000),
            (20, 10_000),
            (50, 25_000),
            (100, 50_000),
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

    /// Values outside the range 10...1000 are clamped automatically.
    ///
    /// WHY CLAMPING:
    /// JSON from SwiftData may contain invalid data (corruption, old schema).
    /// Clamping in init() protects against crashes: tokenBudget < 0 or unreasonably large.
    /// IT-11: Upper bound extended from 100 to 1000 to support deep context setting.
    @Test("Clamping: значения вне диапазона 10...1000 зажимаются")
    func clampingOutOfRange() {
        // Too small → clamped to 10
        let tooSmall = AppConfig(maxMessagesInContext: 3)
        #expect(tooSmall.maxMessagesInContext == 10)
        #expect(tooSmall.tokenBudget == 5_000)

        // Too large → clamped to 1000
        let tooBig = AppConfig(maxMessagesInContext: 9999)
        #expect(tooBig.maxMessagesInContext == 1000)
        #expect(tooBig.tokenBudget == 500_000)

        // Boundary values — not clamped
        let minValid = AppConfig(maxMessagesInContext: 10)
        #expect(minValid.maxMessagesInContext == 10)

        let maxValid = AppConfig(maxMessagesInContext: 1000)
        #expect(maxValid.maxMessagesInContext == 1000)
    }

    /// Default config (shared) has tokenBudget = 20 × 500 = 10,000.
    @Test("AppConfig.shared: tokenBudget = 10,000 (20 сообщений × 500)")
    func sharedTokenBudget() {
        let config = AppConfig.shared
        #expect(config.maxMessagesInContext == 20)
        #expect(config.tokenBudget == 10_000)
    }

    /// AppConfig(settings:) correctly creates config from ThreadSettings.
    @Test("AppConfig(settings:) создаётся из ThreadSettings корректно")
    func configFromThreadSettings() {
        let settings = ThreadSettings(maxMessagesInContext: 50)
        let config = AppConfig(settings: settings)

        #expect(config.maxMessagesInContext == 50)
        #expect(config.tokenBudget == 25_000)
    }

    // MARK: - Codable tests

    /// AppConfig passes roundtrip encode → decode without loss.
    @Test("AppConfig Codable roundtrip")
    func appConfigCodableRoundtrip() throws {
        let original = AppConfig.shared
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded == original)
    }

    /// Dynamic config also passes Codable roundtrip.
    @Test("AppConfig(maxMessagesInContext:) Codable roundtrip")
    func dynamicConfigCodableRoundtrip() throws {
        let original = AppConfig(maxMessagesInContext: 42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded == original)
        #expect(decoded.maxMessagesInContext == 42)
        #expect(decoded.tokenBudget == 42 * 500)
    }

    // MARK: - Sendable test

    /// AppConfig can be safely passed between actors (Sendable).
    @Test("AppConfig передаётся между акторами без ошибок (Sendable)")
    func appConfigIsSendable() async {
        // This test compiles only if AppConfig: Sendable
        // Removing Sendable causes a compile error, not a runtime error
        let config = AppConfig(maxMessagesInContext: 30)

        let result = await Task.detached {
            return config.tokenBudget
        }.value

        #expect(result == 30 * 500)
    }
}
