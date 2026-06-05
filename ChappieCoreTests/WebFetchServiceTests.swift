// WebFetchServiceTests.swift
// ChappieCoreTests
//
// Tests for WebFetchService — URL validation, HTML stripping, selector extraction,
// size limit, and error handling.
//
// STRATEGY:
// WebFetchService is an actor — all calls use `await`.
// Network tests use real HTTP requests against stable public endpoints.
// If the endpoint is unreachable (result starts with ❌) — the test returns early
// without failing, since network availability is outside our control in CI.

import Testing
import Foundation
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

    @Test func allErrorsStartWithRedX() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let badURLs = ["ftp://x.com", "", "not a url", "file:///etc/passwd", "javascript:x"]
        for url in badURLs {
            let result = await service.fetch(urlString: url)
            #expect(result.hasPrefix("❌"), "Expected ❌ for '\(url)', got: \(result)")
        }
    }

    // MARK: - Size Limit

    @Test func sizeLimitTruncatesContent() async {
        let service = WebFetchService(maxOutputLength: 50, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")
        guard !result.hasPrefix("❌") else { return } // network unavailable — skip

        let containsTruncationNote = result.contains("[content truncated:")
        let isShort = result.count <= 50
        #expect(containsTruncationNote || isShort,
            "Expected truncation note or short content, got: \(result.prefix(100))")
    }

    // MARK: - HTML Stripping

    @Test func htmlStrippingRemovesHTMLTags() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")
        guard !result.hasPrefix("❌") else { return }

        #expect(!result.lowercased().contains("<script"), "Output must not contain raw <script> tags")
        #expect(!result.lowercased().contains("<style"), "Output must not contain raw <style> tags")
        #expect(!result.contains("</div>"), "Output must not contain </div>")
        #expect(!result.contains("<html"), "Output must not contain <html")
    }

    @Test func htmlStrippingRemovesScriptTags() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")
        guard !result.hasPrefix("❌") else { return }

        #expect(!result.lowercased().contains("<script"), "Output must not contain raw <script> tags")
        #expect(!result.lowercased().contains("<style"), "Output must not contain raw <style> tags")
    }

    // MARK: - Real HTTP Fetch

    @Test func fetchHTTPSPage() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://example.com")
        guard !result.hasPrefix("❌") else { return }

        #expect(!result.isEmpty, "Fetched page should produce non-empty text")
    }

    @Test func fetchRealPageReturnsNonEmptyText() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/html")
        guard !result.hasPrefix("❌") else { return }

        #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Fetched page should produce non-empty text")
    }

    // MARK: - HTTP Error Handling

    @Test func http404ReturnsError() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/status/404")
        // If network is unavailable, the result will also start with ❌ — that's fine
        guard !result.contains("timed out") && !result.contains("network error") else { return }

        #expect(result.hasPrefix("❌"), "HTTP 404 should return error: \(result)")
        #expect(result.contains("404"), "Error should mention status code: \(result)")
    }

    @Test func http500ReturnsError() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://httpbin.org/status/500")
        guard !result.contains("timed out") && !result.contains("network error") else { return }

        #expect(result.hasPrefix("❌"), "HTTP 500 should return error: \(result)")
        #expect(result.contains("500"), "Error should mention status code: \(result)")
    }

    // MARK: - Selector

    @Test func tagSelectorFiltersContent() async {
        let service = WebFetchService(maxOutputLength: 500, timeoutSeconds: 15)
        let result = await service.fetch(urlString: "https://example.com", selector: "body")
        guard !result.hasPrefix("❌") else { return }

        #expect(!result.isEmpty, "Fetching with 'body' selector should return content")
    }
}
