// WebFetchService+Stripping.swift
// ChappieCore
//
// HTML → plain text: noise removal, block element newlines, entity decoding, size limit.

import Foundation

extension WebFetchService {

    // MARK: - HTML Stripping

    /// Removes HTML markup and returns clean, readable plain text.
    ///
    /// STRATEGY:
    /// 1. Remove entire subtrees of noise elements (script, style, nav, header, footer, etc.)
    /// 2. Replace block-level elements with newlines to preserve paragraph structure.
    /// 3. Strip all remaining tags.
    /// 4. Decode HTML entities.
    /// 5. Collapse excessive whitespace.
    func stripHTML(_ html: String) -> String {
        var text = html

        let noiseElements = ["script", "style", "nav", "header", "footer", "aside",
                             "noscript", "iframe", "form", "button", "select", "textarea",
                             "svg", "canvas", "figure", "figcaption", "picture",
                             "advertisement", "banner", "cookie", "popup"]
        for tag in noiseElements {
            text = removeElementSubtree(from: text, tag: tag)
        }

        let blockElements = ["p", "div", "section", "article", "main", "h1", "h2", "h3",
                             "h4", "h5", "h6", "li", "tr", "td", "th", "blockquote",
                             "pre", "code", "br", "hr"]
        for tag in blockElements {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "<\(tag.uppercased())[^>]*>", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "</\(tag)>", with: "\n", options: .caseInsensitive)
        }

        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        let lines = text.components(separatedBy: "\n")
        text = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a complete HTML element subtree: <tag ...>...</tag> including all nested content.
    func removeElementSubtree(from html: String, tag: String) -> String {
        let pattern = "<\(tag)[\\s>][\\s\\S]*?</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        var result = html
        var previousLength = -1
        // Repeat until stable — handles consecutive same-tag elements
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
    func decodeHTMLEntities(_ text: String) -> String {
        var result = text

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

    /// Truncates text to maxOutputLength, appending a note if content was cut.
    func applyLimit(_ text: String) -> String {
        guard text.count > maxOutputLength else { return text }
        let removed = text.count - maxOutputLength
        return String(text.prefix(maxOutputLength)) + "\n\n[content truncated: \(removed) chars removed]"
    }
}
