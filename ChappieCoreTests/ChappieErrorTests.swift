// ChappieErrorTests.swift
// ChappieCoreTests
//
// Unit tests for ChappieError — the centralized error enum.
//
// WHY TEST ERRORS: ChappieError is a public contract — error descriptions are
// shown to the user. If someone renames a case or changes errorDescription text,
// the test immediately signals the contract is broken.
//
// PRINCIPLE: Verify that errorDescription is non-nil and contains key words.
// Avoid exact string matching — that is brittle. Test the meaning instead.

import Testing
import Foundation
@testable import ChappieCore

@Suite("ChappieError Tests")
struct ChappieErrorTests {

    // MARK: - errorDescription

    @Test("networkError description contains the passed message")
    func networkErrorDescription() {
        let error = ChappieError.networkError("connection lost")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("connection lost"))
    }

    @Test("fileSystemError description contains the passed message")
    func fileSystemErrorDescription() {
        let error = ChappieError.fileSystemError("file not found")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("file not found"))
    }

    @Test("parsingError description contains the passed message")
    func parsingErrorDescription() {
        let error = ChappieError.parsingError("invalid JSON")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("invalid JSON"))
    }

    @Test("memoryError description contains the passed message")
    func memoryErrorDescription() {
        let error = ChappieError.memoryError("database unavailable")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("database unavailable"))
    }

    @Test("aiContextLimitExceeded returns a non-empty description")
    func aiContextLimitExceededDescription() {
        let error = ChappieError.aiContextLimitExceeded
        let description = error.errorDescription ?? ""

        // No associated value — just verify a description exists
        #expect(!description.isEmpty)
    }

    @Test("unknown error description contains the passed message")
    func unknownErrorDescription() {
        let error = ChappieError.unknown("something went wrong")
        let description = error.errorDescription ?? ""

        #expect(!description.isEmpty)
        #expect(description.contains("something went wrong"))
    }

    // MARK: - Sendable

    @Test("ChappieError is safely passable across actors (Sendable)")
    func chappieErrorIsSendable() async {
        // Compiles only if ChappieError: Sendable
        let error = ChappieError.networkError("test")

        let result = await Task.detached {
            return error.errorDescription ?? ""
        }.value

        #expect(!result.isEmpty)
    }

    // MARK: - LocalizedError conformance

    @Test("All ChappieError cases have a non-empty errorDescription")
    func allCasesHaveDescription() {
        let errors: [ChappieError] = [
            .networkError("x"),
            .fileSystemError("x"),
            .parsingError("x"),
            .memoryError("x"),
            .aiContextLimitExceeded,
            .unknown("x")
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty, "Case \(error) is missing errorDescription")
        }
    }
}
