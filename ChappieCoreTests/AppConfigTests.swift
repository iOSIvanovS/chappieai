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

    @Test("AppConfig.shared — singleton returns same instance")
    func sharedIsSingleton() {
        let config1 = AppConfig.shared
        let config2 = AppConfig.shared
        #expect(config1 == config2)
    }

    @Test("maxOrchestratorSteps is within reasonable range [10...1000]")
    func maxOrchestratorStepsIsReasonable() {
        let config = AppConfig.shared
        #expect(config.maxOrchestratorSteps >= 10)
        #expect(config.maxOrchestratorSteps <= 1000)
    }

    @Test("maxMessagesInContext is within valid range [10...1000]")
    func maxMessagesInContextIsReasonable() {
        let config = AppConfig.shared
        #expect(config.maxMessagesInContext >= 10)
        #expect(config.maxMessagesInContext <= 1000)
    }

    @Test("requestTimeoutSeconds is sufficient for complex tasks (>= 60s)")
    func requestTimeoutIsAdequate() {
        let config = AppConfig.shared
        #expect(config.requestTimeoutSeconds >= 60)
        #expect(config.requestTimeoutSeconds <= 600)
    }

    @Test("connectionTimeoutSeconds is within reasonable range [10...60]")
    func connectionTimeoutIsReasonable() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds >= 10)
        #expect(config.connectionTimeoutSeconds <= 60)
    }

    @Test("connectionTimeout < requestTimeout (logical constraint)")
    func connectionTimeoutLessThanRequestTimeout() {
        let config = AppConfig.shared
        #expect(config.connectionTimeoutSeconds < config.requestTimeoutSeconds)
    }

    // MARK: - Dynamic config tests

    /// tokenBudget is computed as maxMessagesInContext × 500.
    @Test("tokenBudget = maxMessagesInContext × 500")
    func tokenBudgetFormula() {
        let testCases: [(messages: Int, expectedBudget: Int)] = [
            (10,   5_000),
            (100,  50_000),
            (200,  100_000),
            (500,  250_000),
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

    /// Values outside 10...1000 are clamped automatically.
    @Test("Clamping: values outside 10...1000 are clamped")
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

    @Test("AppConfig(settings:) is created from ThreadSettings correctly")
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

    @Test("AppConfig can be passed between actors (Sendable)")
    func appConfigIsSendable() async {
        let config = AppConfig(maxMessagesInContext: 300)

        let result = await Task.detached {
            return config.tokenBudget
        }.value

        #expect(result == 300 * 500)
    }
}
