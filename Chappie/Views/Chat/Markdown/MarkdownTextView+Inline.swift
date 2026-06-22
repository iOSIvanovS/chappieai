// MarkdownTextView+Inline.swift
// Chappie
//
// InlineTextView — renders **bold**, *italic*, `code` inline markup.

import SwiftUI

// MARK: - Inline text

/// Renders a string with inline markup (**bold**, *italic*, `code`).
///
/// Color is passed via .foregroundStyle() — NOT via AttributedString.foregroundColor,
/// which is unreliable inside ScrollView on macOS.
struct InlineTextView: View {

    let text: String; let fontSize: CGFloat; let color: Color
    private let attributedString: AttributedString

    init(text: String, fontSize: CGFloat, color: Color, weight: Font.Weight = .regular) {
        self.text = text; self.fontSize = fontSize; self.color = color
        self.attributedString = InlineTextView.build(text: text, fontSize: fontSize, weight: weight)
    }

    var body: some View {
        Text(attributedString).foregroundStyle(color).textSelection(.enabled)
    }

    private static func build(text: String, fontSize: CGFloat, weight: Font.Weight) -> AttributedString {
        var result = AttributedString()
        var remaining = text

        while !remaining.isEmpty {
            // Bold: **text**
            if let o = remaining.range(of: "**"),
               let c = remaining.range(of: "**", range: o.upperBound..<remaining.endIndex) {
                let before = String(remaining[remaining.startIndex..<o.lowerBound])
                if !before.isEmpty { var s = AttributedString(before); s.font = .system(size: fontSize, weight: weight); result.append(s) }
                var s = AttributedString(String(remaining[o.upperBound..<c.lowerBound]))
                s.font = .system(size: fontSize, weight: .bold); result.append(s)
                remaining = String(remaining[c.upperBound...]); continue
            }
            // Inline code: `code`
            if let o = remaining.range(of: "`"),
               let c = remaining.range(of: "`", range: o.upperBound..<remaining.endIndex) {
                let before = String(remaining[remaining.startIndex..<o.lowerBound])
                if !before.isEmpty { var s = AttributedString(before); s.font = .system(size: fontSize, weight: weight); result.append(s) }
                var s = AttributedString(String(remaining[o.upperBound..<c.lowerBound]))
                s.font = .system(size: fontSize - 1, design: .monospaced); result.append(s)
                remaining = String(remaining[c.upperBound...]); continue
            }
            // Italic: *text*
            if let o = remaining.range(of: "*"),
               let c = remaining.range(of: "*", range: o.upperBound..<remaining.endIndex) {
                let nextIdx = remaining.index(after: o.lowerBound)
                if nextIdx < remaining.endIndex && remaining[nextIdx] == "*" {
                    var s = AttributedString(String(remaining[remaining.startIndex...o.lowerBound]))
                    s.font = .system(size: fontSize, weight: weight); result.append(s)
                    remaining = String(remaining[nextIdx...]); continue
                }
                let before = String(remaining[remaining.startIndex..<o.lowerBound])
                if !before.isEmpty { var s = AttributedString(before); s.font = .system(size: fontSize, weight: weight); result.append(s) }
                var s = AttributedString(String(remaining[o.upperBound..<c.lowerBound]))
                s.font = Font.system(size: fontSize, weight: weight).italic(); result.append(s)
                remaining = String(remaining[c.upperBound...]); continue
            }
            // Plain
            var s = AttributedString(remaining); s.font = .system(size: fontSize, weight: weight); result.append(s); break
        }
        return result
    }
}
