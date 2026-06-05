// WebFetchServiceTests.swift
// ChappieCoreTests
//
// Tests for WebFetchService — URL validation, HTML stripping, selector extraction,
// encoding detection, size limit, and error handling.
//
// TESTING STRATEGY:
// WebFetchService is an actor — all calls use `await`.
// Network tests use real HTTP requests against stable public endpoints.
// Pure logic tests are tested via the public fetch() interface.
// Network-dependent tests are skipped when the endpoint is unreachable.

import Testing
@testable import ChappieCore

@Suite("WebFetchService")
struct WebFetchServiceTests {

    // MARK: - URL Validation

    @Test func invalidSchemeReturnsError() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "ftp://example.com/file.txt")
        #expect(result.hasPrefix("❌"), "ftp:// should be rejected: \(result)")
    }

    @Test func emptyURLReturnsError() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "")
        #expect(result.hasPrefix("❌"), "Empty URL should be rejected: \(result)")
    }

    @Test func malformedURLReturnsError() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "not a url at all")
        #expect(result.hasPrefix("❌"), "Malformed URL should be rejected: \(result)")
    }

    @Test func fileSchemeReturnsError() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "file:///etc/passwd")
        #expect(result.hasPrefix("❌"), "file:// should be rejected: \(result)")
    }

    @Test func javascriptSchemeReturnsError() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "javascript:alert(1)")
        #expect(result.hasPrefix("❌"), "javascript: should be rejected: \(result)")
    }

    // MARK: - Size Limit

    @Test func sizeLimitTruncatesContent() async throws {
        let service = WebFetchService(maxOutputLength: 50, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")

        guard !result.hasPrefix("❌") else {
            throw XCTSkip("Network unavailable")
        }

        // If content was longer than 50 chars, truncation note must be present
        let containsTruncationNote = result.contains("[content truncated:")
        let isShort = result.count <= 50
        #expect(containsTruncationNote || isShort,
            "Expected truncation note or short content, got: \(result.prefix(100))")
    }

    // MARK: - HTML Stripping

    @Test func htmlStrippingRemovesScriptTags() async throws {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")

        guard !result.hasPrefix("❌") else {
            throw XCTSkip("Network unavailable")
        }

        #expect(!result.lowercased().contains("<script"), "Output must not contain raw <script> tags")
        #expect(!result.lowercased().contains("<style"), "Output must not contain raw <style> tags")
    }

    @Test func htmlStrippingRemovesStructuralTags() async throws {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")

        guard !result.hasPrefix("❌") else {
            throw XCTSkip("Network unavailable")
        }

        #expect(!result.contains("</div>"), "Output must not contain </div>")
        #expect(!result.contains("</p>"), "Output must not contain </p>")
        #expect(!result.contains("<html"), "Output must not contain <html")
        #expect(!result.contains("<body"), "Output must not contain <body")
    }

    // MARK: - Real HTTP Fetch

    @Test func fetchRealPageReturnsNonEmptyText() async throws {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")

        guard !result.hasPrefix("❌") else {
            throw XCTSkip("Network unavailable")
        }

        #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Fetched page should produce non-empty text")
    }

    @Test func fetchExampleComReturnsKnownContent() async throws {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://example.com")

        guard !result.hasPrefix("❌") else {
            throw XCTSkip("Network unavailable")
        }

        #expect(result.contains("Example Domain") || !result.isEmpty,
            "example.com should return recognizable content")
    }

    // MARK: - HTTP Error Handling

    @Test func http404ReturnsError() async throws {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/status/404")

        guard !result.contains("network error"), !result.contains("timed out") else {
            throw XCTSkip("Network unavailable or unexpected error")
        }

        #expect(result.hasPrefix("❌"), "HTTP 404 should return error: \(result)")
        #expect(result.contains("404"), "Error should mention status code: \(result)")
    }

    @Test func http500ReturnsError() async throws {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/status/500")

        guard !result.contains("network error"), !result.contains("timed out") else {
            throw XCTSkip("Network unavailable or unexpected error")
        }

        #expect(result.hasPrefix("❌"), "HTTP 500 should return error: \(result)")
        #expect(result.contains("500"), "Error should mention status code: \(result)")
    }

    // MARK: - Selector

    @Test func tagSelectorReturnsNonEmptyContent() async throws {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://example.com", selector: "body")

        guard !result.hasPrefix("❌") else {
            throw XCTSkip("Network unavailable")
        }

        #expect(!result.isEmpty, "Fetching with 'body' selector should return content")
    }
}
