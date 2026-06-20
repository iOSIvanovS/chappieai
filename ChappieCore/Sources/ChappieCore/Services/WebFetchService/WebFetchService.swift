// WebFetchService.swift
// ChappieCore
//
// Core: init, fetch(), encoding detection.
// HTML parsing split into +Selector and +Stripping extensions.

import Foundation

public actor WebFetchService {

    // MARK: - Constants

    let maxOutputLength: Int
    let timeoutSeconds: TimeInterval

    // MARK: - Init

    public init(maxOutputLength: Int = 100_000, timeoutSeconds: TimeInterval = 30) {
        self.maxOutputLength = maxOutputLength
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Public API

    /// Fetches the page at `urlString`, optionally filters by `selector`, returns clean text.
    public func fetch(urlString: String, selector: String? = nil) async -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            return "❌ web_fetch: invalid URL '\(urlString)'. Only http/https URLs are supported."
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        config.httpAdditionalHeaders = ["User-Agent": "Chappie/1.0 (AI assistant; web_fetch tool)"]
        let session = URLSession(configuration: config)

        let html: String
        do {
            let (data, response) = try await session.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                return "❌ web_fetch: HTTP \(httpResponse.statusCode) for \(urlString)"
            }

            html = decodeHTML(data: data, response: response)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                return "❌ web_fetch: request timed out after \(Int(timeoutSeconds))s for \(urlString)"
            }
            return "❌ web_fetch: network error — \(error.localizedDescription)"
        }

        let htmlToProcess: String
        if let sel = selector, !sel.trimmingCharacters(in: .whitespaces).isEmpty {
            htmlToProcess = extractBySelector(html: html, selector: sel.trimmingCharacters(in: .whitespaces))
        } else {
            htmlToProcess = html
        }

        let text = stripHTML(htmlToProcess)
        let result = applyLimit(text)

        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ web_fetch: page was fetched but no readable text content was extracted from \(urlString)"
        }

        return result
    }

    // MARK: - Encoding Detection

    /// Decodes raw HTML data, detecting encoding from Content-Type header or meta charset.
    func decodeHTML(data: Data, response: URLResponse) -> String {
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
            if let encoding = parseCharsetEncoding(from: contentType),
               let str = String(data: data, encoding: encoding) {
                return str
            }
        }

        if let str = String(data: data, encoding: .utf8) { return str }
        if let str = String(data: data, encoding: .isoLatin1) { return str }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses charset from a Content-Type string like "text/html; charset=windows-1251".
    func parseCharsetEncoding(from contentType: String) -> String.Encoding? {
        let lower = contentType.lowercased()
        guard let range = lower.range(of: "charset=") else { return nil }
        let after = String(lower[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: CharacterSet(charactersIn: " ;,"))[0]

        switch after {
        case "utf-8", "utf8":           return .utf8
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1252", "cp1252": return .windowsCP1252
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(after as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                return String.Encoding(rawValue: nsEncoding)
            }
            return nil
        }
    }
}
