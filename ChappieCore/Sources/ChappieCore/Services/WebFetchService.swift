// WebFetchService.swift
// ChappieCore
//
// WHY THIS FILE:
// Fetches web pages and extracts meaningful text content for the AI agent.
// Used by ToolExecutionService to implement the `web_fetch` tool.
//
// DESIGN DECISIONS:
// - No external dependencies — Foundation only.
// - Smart HTML stripping: removes chrome (nav, header, footer, aside, script, style, ads),
//   keeps content (main, article, section, p, headings, li, td, th, pre, code, blockquote).
// - Optional CSS-style selector: filter by tag name, .class, or #id before stripping.
// - Size limit: 100 000 characters AFTER stripping. If exceeded — truncated from end
//   with a note "[content truncated: N chars removed]".
// - Timeout: 30 seconds (configurable via init).
// - Returns plain text — no HTML, no markdown artifacts.
//
// SELECTOR SYNTAX SUPPORTED:
//   "article"       → match by tag name
//   ".my-class"     → match by class attribute (contains)
//   "#my-id"        → match by id attribute (exact)
//   nil / ""        → no filtering, process entire body

import Foundation

public actor WebFetchService {

    // MARK: - Constants

    /// Maximum character count of extracted text before truncation.
    private let maxOutputLength: Int

    /// Request timeout in seconds.
    private let timeoutSeconds: TimeInterval

    // MARK: - Init

    public init(maxOutputLength: Int = 100_000, timeoutSeconds: TimeInterval = 30) {
        self.maxOutputLength = maxOutputLength
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Public API

    /// Fetches the page at `urlString`, optionally filters by `selector`, and returns clean text.
    ///
    /// - Parameters:
    ///   - urlString: Absolute URL string (http or https).
    ///   - selector: Optional CSS-like selector: tag name, ".class", or "#id".
    /// - Returns: Extracted text content, or an error description string starting with "❌".
    public func fetch(urlString: String, selector: String? = nil) async -> String {
        // Validate URL
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            return "❌ web_fetch: invalid URL '\(urlString)'. Only http/https URLs are supported."
        }

        // Build URLSession with custom timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        // Identify ourselves politely
        config.httpAdditionalHeaders = ["User-Agent": "Chappie/1.0 (AI assistant; web_fetch tool)"]
        let session = URLSession(configuration: config)

        // Fetch HTML
        let html: String
        do {
            let (data, response) = try await session.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                return "❌ web_fetch: HTTP \(httpResponse.statusCode) for \(urlString)"
            }

            // Detect encoding from HTTP headers or meta charset; fall back to UTF-8
            html = decodeHTML(data: data, response: response)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                return "❌ web_fetch: request timed out after \(Int(timeoutSeconds))s for \(urlString)"
            }
            return "❌ web_fetch: network error — \(error.localizedDescription)"
        }

        // Apply selector filter if provided
        let htmlToProcess: String
        if let sel = selector, !sel.trimmingCharacters(in: .whitespaces).isEmpty {
            htmlToProcess = extractBySelector(html: html, selector: sel.trimmingCharacters(in: .whitespaces))
        } else {
            htmlToProcess = html
        }

        // Strip HTML → plain text
        let text = stripHTML(htmlToProcess)

        // Apply size limit
        let result = applyLimit(text)

        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ web_fetch: page was fetched but no readable text content was extracted from \(urlString)"
        }

        return result
    }

    // MARK: - Encoding Detection

    /// Decodes raw HTML data, detecting encoding from Content-Type header or meta charset.
    private func decodeHTML(data: Data, response: URLResponse) -> String {
        // 1. Try encoding from Content-Type header
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
            if let encoding = parseCharsetEncoding(from: contentType),
               let str = String(data: data, encoding: encoding) {
                return str
            }
        }

        // 2. Try UTF-8 (most common)
        if let str = String(data: data, encoding: .utf8) {
            return str
        }

        // 3. Try ISO-8859-1 (legacy fallback)
        if let str = String(data: data, encoding: .isoLatin1) {
            return str
        }

        // 4. Last resort: lossy UTF-8
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses charset from a Content-Type string like "text/html; charset=windows-1251".
    private func parseCharsetEncoding(from contentType: String) -> String.Encoding? {
        let lower = contentType.lowercased()
        guard let range = lower.range(of: "charset=") else { return nil }
        let after = String(lower[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: CharacterSet(charactersIn: " ;,"))[0]

        switch after {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1251", "cp1251":
            return .windowsCP1251
        case "windows-1252", "cp1252":
            return .windowsCP1252
        default:
            // Try CFString encoding lookup for exotic charsets
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(after as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                return String.Encoding(rawValue: nsEncoding)
            }
            return nil
        }
    }

    // MARK: - Selector Extraction

    /// Extracts the first matching element's inner HTML by a CSS-like selector.
    ///
    /// Supported:
    ///   "article"     → <article ...>...</article>
    ///   ".my-class"   → first element with class containing "my-class"
    ///   "#my-id"      → first element with id="my-id"
    private func extractBySelector(html: String, selector: String) -> String {
        if selector.hasPrefix("#") {
            // ID selector: find element with id="..."
            let idValue = String(selector.dropFirst())
            return extractByAttribute(html: html, attribute: "id", value: idValue, exact: true)
                ?? html

        } else if selector.hasPrefix(".") {
            // Class selector: find element whose class contains the value
            let className = String(selector.dropFirst())
            return extractByAttribute(html: html, attribute: "class", value: className, exact: false)
                ?? html

        } else {
            // Tag selector: find <tagname ...>...</tagname>
            return extractByTag(html: html, tag: selector) ?? html
        }
    }

    /// Finds the first occurrence of <tag ...>...</tag> and returns its inner HTML.
    private func extractByTag(html: String, tag: String) -> String? {
        let lower = html.lowercased()
        let openTag = "<\(tag.lowercased())"

        guard let openRange = lower.range(of: openTag) else { return nil }

        // Find the closing >
        guard let closingBracket = lower[openRange.upperBound...].firstIndex(of: ">") else { return nil }
        let contentStart = lower.index(after: closingBracket)

        // Find matching closing tag (simple non-nested search — good enough for content tags)
        let closeTag = "</\(tag.lowercased())>"
        guard let closeRange = lower[contentStart...].range(of: closeTag) else { return nil }

        return String(html[contentStart..<closeRange.lowerBound])
    }

    /// Finds the first element with a specific attribute value and returns its inner HTML.
    private func extractByAttribute(html: String, attribute: String, value: String, exact: Bool) -> String? {
        // Pattern: attribute="...value..." (handles single/double quotes and no-quotes)
        let pattern = exact
            ? "\(attribute)=[\"']?\(NSRegularExpression.escapedPattern(for: value))[\"']?"
            : "\(attribute)=[\"'][^\"']*\(NSRegularExpression.escapedPattern(for: value))[^\"']*[\"']"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let nsHtml = html as NSString
        let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
        guard let matchRange = match?.range else { return nil }

        // Walk back to find the opening < of the element
        let matchStart = matchRange.location
        var tagStart = matchStart
        while tagStart > 0 && nsHtml.character(at: tagStart) != UInt16(("<" as UnicodeScalar).value) {
            tagStart -= 1
        }

        // Extract tag name
        let afterBracket = tagStart + 1
        var tagNameEnd = afterBracket
        while tagNameEnd < nsHtml.length {
            let ch = nsHtml.character(at: tagNameEnd)
            if ch == UInt16((" " as UnicodeScalar).value)
                || ch == UInt16((">" as UnicodeScalar).value)
                || ch == UInt16(("\n" as UnicodeScalar).value) {
                break
            }
            tagNameEnd += 1
        }

        let tagName = nsHtml.substring(with: NSRange(location: afterBracket, length: tagNameEnd - afterBracket)).lowercased()
        guard !tagName.isEmpty else { return nil }

        // Find end of opening tag
        let searchFrom = matchRange.upperBound
        var closingBracket = searchFrom
        while closingBracket < nsHtml.length && nsHtml.character(at: closingBracket) != UInt16((">" as UnicodeScalar).value) {
            closingBracket += 1
        }
        let contentStart = closingBracket + 1

        // Find closing tag
        let closeTag = "</\(tagName)>"
        let remainingHtml = nsHtml.substring(from: contentStart) as NSString
        let closeRange = remainingHtml.range(of: closeTag, options: .caseInsensitive)
        guard closeRange.location != NSNotFound else { return nil }

        return remainingHtml.substring(to: closeRange.location)
    }

    // MARK: - HTML Stripping

    /// Removes HTML markup and returns clean, readable plain text.
    ///
    /// STRATEGY:
    /// 1. Remove entire subtrees of noise elements (script, style, nav, header, footer, etc.)
    /// 2. Replace block-level elements with newlines to preserve paragraph structure.
    /// 3. Strip all remaining tags.
    /// 4. Decode HTML entities.
    /// 5. Collapse excessive whitespace.
    private func stripHTML(_ html: String) -> String {
        var text = html

        // Step 1: Remove entire subtrees of noise elements
        let noiseElements = ["script", "style", "nav", "header", "footer", "aside",
                             "noscript", "iframe", "form", "button", "select", "textarea",
                             "svg", "canvas", "figure", "figcaption", "picture",
                             "advertisement", "banner", "cookie", "popup"]
        for tag in noiseElements {
            text = removeElementSubtree(from: text, tag: tag)
        }

        // Step 2: Replace block elements with newlines to preserve structure
        let blockElements = ["p", "div", "section", "article", "main", "h1", "h2", "h3",
                             "h4", "h5", "h6", "li", "tr", "td", "th", "blockquote",
                             "pre", "code", "br", "hr"]
        for tag in blockElements {
            // Opening tags → newline before content
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>",
                with: "\n",
                options: .regularExpression
            )
            text = text.replacingOccurrences(
                of: "<\(tag.uppercased())[^>]*>",
                with: "\n",
                options: .regularExpression
            )
            // Closing tags → newline after content
            text = text.replacingOccurrences(of: "</\(tag)>", with: "\n", options: .caseInsensitive)
        }

        // Step 3: Strip all remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Step 4: Decode common HTML entities
        text = decodeHTMLEntities(text)

        // Step 5: Collapse whitespace — multiple spaces/tabs → single space,
        //         more than 2 consecutive newlines → double newline
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // Step 6: Trim each line
        let lines = text.components(separatedBy: "\n")
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        text = trimmedLines.filter { !$0.isEmpty }.joined(separator: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a complete HTML element subtree: <tag ...>...</tag> including all nested content.
    private func removeElementSubtree(from html: String, tag: String) -> String {
        // Pattern matches the full element including nested tags of the same type.
        // Simple regex approach — handles most real-world cases without a full HTML parser.
        let pattern = "<\(tag)[\\s>][\\s\\S]*?</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        var result = html
        // Repeat until no more matches (handles nested same-tag elements)
        var previousLength = -1
        while result.count != previousLength {
            previousLength = result.count
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    /// Decodes common HTML entities to their Unicode equivalents.
    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        // Named entities (most common)
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&laquo;", "«"), ("&raquo;", "»"), ("&copy;", "©"),
            ("&reg;", "®"), ("&trade;", "™"), ("&euro;", "€"),
            ("&pound;", "£"), ("&yen;", "¥"), ("&cent;", "¢"),
            ("&bull;", "•"), ("&middot;", "·"), ("&times;", "×"),
            ("&divide;", "÷"), ("&plusmn;", "±"), ("&frac12;", "½"),
            ("&frac14;", "¼"), ("&frac34;", "¾")
        ]
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // Numeric decimal entities: &#1234;
        if let decRegex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let nsResult = result as NSString
            let matches = decRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            // Process in reverse order to preserve string indices
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange]),
                   let scalar = Unicode.Scalar(codePoint),
                   let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }

        // Numeric hex entities: &#x1F600;
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let nsResult = result as NSString
            let matches = hexRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint),
                   let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }

        return result
    }

    // MARK: - Size Limit

    /// Truncates text to maxOutputLength characters, appending a note if truncated.
    private func applyLimit(_ text: String) -> String {
        guard text.count > maxOutputLength else { return text }
        let removed = text.count - maxOutputLength
        let truncated = String(text.prefix(maxOutputLength))
        return truncated + "\n\n[content truncated: \(removed) chars removed]"
    }
}
