// WebFetchService+Selector.swift
// ChappieCore
//
// CSS-like selector extraction: tag name, .class, #id.

import Foundation

extension WebFetchService {

    // MARK: - Selector Extraction

    /// Extracts the first matching element's inner HTML by a CSS-like selector.
    ///
    /// Supported:
    ///   "article"     → <article ...>...</article>
    ///   ".my-class"   → first element with class containing "my-class"
    ///   "#my-id"      → first element with id="my-id"
    func extractBySelector(html: String, selector: String) -> String {
        if selector.hasPrefix("#") {
            let idValue = String(selector.dropFirst())
            return extractByAttribute(html: html, attribute: "id", value: idValue, exact: true) ?? html
        } else if selector.hasPrefix(".") {
            let className = String(selector.dropFirst())
            return extractByAttribute(html: html, attribute: "class", value: className, exact: false) ?? html
        } else {
            return extractByTag(html: html, tag: selector) ?? html
        }
    }

    /// Finds the first occurrence of <tag ...>...</tag> and returns its inner HTML.
    func extractByTag(html: String, tag: String) -> String? {
        let lower = html.lowercased()
        let openTag = "<\(tag.lowercased())"

        guard let openRange = lower.range(of: openTag) else { return nil }
        guard let closingBracket = lower[openRange.upperBound...].firstIndex(of: ">") else { return nil }
        let contentStart = lower.index(after: closingBracket)

        let closeTag = "</\(tag.lowercased())>"
        guard let closeRange = lower[contentStart...].range(of: closeTag) else { return nil }

        return String(html[contentStart..<closeRange.lowerBound])
    }

    /// Finds the first element with a specific attribute value and returns its inner HTML.
    func extractByAttribute(html: String, attribute: String, value: String, exact: Bool) -> String? {
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
}
