// MarkdownTextView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Chappie responses heavily use markdown: code blocks (Swift/bash),
// inline code, bold text, headings. Standard SwiftUI Text doesn't support
// code blocks with syntax highlighting. This component fills that gap.
//
// DESIGN PHILOSOPHY (Apple HIG + Xcode Intelligence Panel):
// - Code blocks: adaptive background — dark (#1E1E1E) in Dark Mode,
//   light (#FFFFFF / #F5F5F5) in Light Mode. Mirrors Xcode behavior.
// - Typography: SF Pro Text 14pt with lineSpacing 5 — optimal for reading
//   long technical responses. Apple recommends 1.4–1.6× line-height.
// - Inline code: monospaced font — standard like GitHub/Notion.
// - Copy button in code block — standard in all modern IDEs and chats.
//
// PARSER ARCHITECTURE:
// Simple linear line-by-line parser — not RegEx, not AST.
// Reason: Chappie Swift responses have predictable structure.
// A full markdown parser (CommonMark) would be overkill and add a dependency.
// Handles:
//   1. Code blocks: ```lang\n...\n```
//   2. Headings: # ## ###
//   3. Bold: **text**
//   4. Inline code: `code`
//   5. Tables: | col | col |
//   6. Plain text with correct typography
//
// THEME ADAPTABILITY:
// All colors in CodeBlockView and SyntaxHighlightedText are read via
// @Environment(\.colorScheme) and select the appropriate palette.
// Light theme = Xcode Default Light, Dark = Xcode Default Dark.
//
// BAD RANGE FIX (TEXTKIT-RANGE):
// "bad range for [%{public}s]" is a TextKit warning that fires when:
//   1. MarkdownBlock.id was non-stable (UUID() for dividers) — SwiftUI
//      reconstructed TextKit storage on every render pass.
//   2. String.Index ↔ AttributedString.Index mismatch on unicode chars
//      (Cyrillic, emoji) in syntax highlighting methods.
//   3. blocks were recomputed on every render pass (computed var) causing
//      50 simultaneous parses when switching a thread with 50 messages.
// Fixes applied:
//   a) MarkdownTextView stores blocks in init (let), not computed var.
//   b) MarkdownBlock.id uses position index for ALL block types — not just
//      dividers. Content-prefix IDs caused SwiftUI to reuse views across
//      different table sections when row text started identically.
//   c) All applyXxx methods guard Range conversion with optional binding —
//      never force-apply on out-of-bounds unicode index.
//
// PERFORMANCE FIX (TABLE LAYOUT):
// TableBlockView was causing heavy layout passes due to two issues:
//   1. Rectangle().frame(maxHeight: .infinity) as vertical column divider
//      triggers two-pass layout for every row — SwiftUI must measure all
//      cells first, then stretch the divider. With 9 rows × 3 cols this
//      cascades into dozens of layout passes per scroll event.
//      Fix: replaced with Divider().frame(width: 1) — single-pass, height
//      is determined by the row's natural height without extra measurement.
//   2. InlineTextView.buildAttributedString() was called on every render pass
//      because body computed it inline. For a 9-row table this means 27+
//      AttributedString builds per layout pass.
//      Fix: AttributedString is now computed once in init() and stored as
//      a let constant — zero recomputation on subsequent renders.
//
// IMPORTANT (macOS 26):
// The `+` operator for Text is deprecated in macOS 26 — use
// Text("\(Text(...).bold())") string interpolation instead.
// buildInlineText() uses this approach.

import SwiftUI

// MARK: - Syntax color themes

/// Color palette for syntax highlighting.
///
/// Two themes: Light (Xcode Default Light) and Dark (Xcode Default Dark).
/// Stored as structs with static properties — simple and dependency-free.
private struct SyntaxTheme {

    let background: Color
    let headerBackground: Color
    let border: Color
    let labelColor: Color
    let plainText: Color
    let keyword: Color
    let type_: Color
    let string: Color
    let number: Color
    let comment: Color

    // MARK: Xcode Default Dark
    // Colors taken directly from Xcode 15 Default Dark theme.
    static let dark = SyntaxTheme(
        background:       Color(red: 0.118, green: 0.118, blue: 0.118), // #1E1E1E
        headerBackground: Color(red: 0.145, green: 0.145, blue: 0.145), // #252525
        border:           Color(red: 0.250, green: 0.250, blue: 0.250), // #404040
        labelColor:       Color(red: 0.600, green: 0.600, blue: 0.600), // #999999
        plainText:        Color(red: 0.970, green: 0.970, blue: 0.950), // #F7F7F2
        keyword:          Color(red: 0.988, green: 0.373, blue: 0.639), // #FC5FA3
        type_:            Color(red: 0.365, green: 0.847, blue: 1.000), // #5DD8FF
        string:           Color(red: 0.988, green: 0.416, blue: 0.365), // #FC6A5D
        number:           Color(red: 0.816, green: 0.749, blue: 0.412), // #D0BF69
        comment:          Color(red: 0.424, green: 0.475, blue: 0.525)  // #6C7986
    )

    // MARK: Xcode Default Light
    // Colors taken directly from Xcode 15 Default Light theme.
    static let light = SyntaxTheme(
        background:       Color(red: 1.000, green: 1.000, blue: 1.000), // #FFFFFF
        headerBackground: Color(red: 0.953, green: 0.953, blue: 0.953), // #F3F3F3
        border:           Color(red: 0.851, green: 0.851, blue: 0.851), // #D9D9D9
        labelColor:       Color(red: 0.500, green: 0.500, blue: 0.500), // #808080
        plainText:        Color(red: 0.000, green: 0.000, blue: 0.000), // #000000
        keyword:          Color(red: 0.659, green: 0.055, blue: 0.565), // #A80E90 — purple
        type_:            Color(red: 0.110, green: 0.384, blue: 0.655), // #1C6278 — dark blue
        string:           Color(red: 0.773, green: 0.102, blue: 0.086), // #C51A16 — dark red
        number:           Color(red: 0.118, green: 0.400, blue: 0.188), // #1E6630 — dark green
        comment:          Color(red: 0.408, green: 0.435, blue: 0.459)  // #686F75 — gray
    )
}

// MARK: - Block model

/// Structural unit of parsed markdown text.
///
/// All text is split into a sequence of blocks,
/// each rendered in its own way.
///
/// STABLE IDs (TEXTKIT-RANGE FIX):
/// IDs must be stable across render passes — SwiftUI uses them to decide
/// whether to reuse or recreate TextKit storage. Non-stable IDs (e.g. UUID())
/// cause TextKit to reconstruct storage on every render, triggering "bad range".
///
/// CRITICAL BUG FIX (TABLE BLEED):
/// Previously IDs used content prefix: "p_\(text.prefix(40))".
/// When multiple table sections had rows starting with the same text
/// (e.g. "| 1 | **Multi-language..."), their IDs collided — SwiftUI reused
/// the same view instance across sections, causing row content to "bleed"
/// from one table into another.
/// Fix: ALL block types now use positional index in their ID, making every
/// block unique regardless of content similarity.
private enum MarkdownBlock: Identifiable {
    /// Plain text with inline markup (bold, italic, inline code)
    case paragraph(String, index: Int)
    /// Heading level 1–3
    case heading(String, level: Int, index: Int)
    /// Code block with optional language
    case codeBlock(code: String, language: String?, index: Int)
    /// Horizontal divider ---
    case divider(index: Int)
    /// Markdown table: header row + separator + data rows
    case table(headers: [String], rows: [[String]], index: Int)

    var id: String {
        switch self {
        // Position index guarantees uniqueness even when content prefix matches.
        case .paragraph(_, let i):        return "p_\(i)"
        case .heading(_, _, let i):       return "h_\(i)"
        case .codeBlock(_, _, let i):     return "code_\(i)"
        case .divider(let i):             return "div_\(i)"
        case .table(_, _, let i):         return "table_\(i)"
        }
    }
}

// MARK: - Markdown parser

/// Linear line-by-line markdown parser producing a sequence of blocks.
///
/// WHY NOT AttributedString / markdown init:
/// AttributedString(markdown:) doesn't support code blocks with syntax highlighting.
/// We need full control over rendering of each block.
private struct MarkdownParser {

    /// Parses a markdown string into an array of blocks.
    ///
    /// TEXTKIT-RANGE FIX: ALL blocks receive a stable positional index
    /// so their IDs don't change between render passes and never collide.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        // Global block counter — ensures every block has a unique positional ID.
        var blockIndex = 0

        while i < lines.count {
            let line = lines[i]

            // --- Code block: starts with ```
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                // Collect lines until closing ```
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                // Skip closing ```
                if i < lines.count { i += 1 }

                let code = codeLines.joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
                blocks.append(.codeBlock(code: code, language: lang.isEmpty ? nil : lang, index: blockIndex))
                blockIndex += 1
                continue
            }

            // --- Horizontal divider
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider(index: blockIndex))
                blockIndex += 1
                i += 1
                continue
            }

            // --- Headings # ## ###
            if line.hasPrefix("### ") {
                blocks.append(.heading(String(line.dropFirst(4)), level: 3, index: blockIndex))
                blockIndex += 1
                i += 1
                continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(String(line.dropFirst(3)), level: 2, index: blockIndex))
                blockIndex += 1
                i += 1
                continue
            }
            if line.hasPrefix("# ") {
                blocks.append(.heading(String(line.dropFirst(2)), level: 1, index: blockIndex))
                blockIndex += 1
                i += 1
                continue
            }

            // --- Table: line starts with |
            // A markdown table is: header row | separator row (|---|) | data rows
            if trimmed.hasPrefix("|") {
                var tableLines: [String] = [line]
                i += 1
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("|") {
                        tableLines.append(lines[i])
                        i += 1
                    } else {
                        break
                    }
                }

                if let tableBlock = parseTable(tableLines, index: blockIndex) {
                    blocks.append(tableBlock)
                    blockIndex += 1
                } else {
                    // Not a valid table — fall through as paragraphs
                    for tl in tableLines {
                        let tlt = tl.trimmingCharacters(in: .whitespaces)
                        if !tlt.isEmpty {
                            blocks.append(.paragraph(tl, index: blockIndex))
                            blockIndex += 1
                        }
                    }
                }
                continue
            }

            // --- Empty line: paragraph separator
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // --- Plain paragraph: accumulate adjacent lines into one block.
            // Important: avoids creating a separate paragraph per line.
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty
                    || next.hasPrefix("```")
                    || next.hasPrefix("# ")
                    || next.hasPrefix("## ")
                    || next.hasPrefix("### ")
                    || nextTrimmed == "---"
                    || nextTrimmed.hasPrefix("|") {
                    break
                }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n"), index: blockIndex))
            blockIndex += 1
        }

        return blocks
    }

    /// Parses collected pipe-delimited lines into a table block.
    ///
    /// Returns nil if the lines don't form a valid table (need at least header + separator).
    private static func parseTable(_ lines: [String], index: Int) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }

        // Parse a single pipe-delimited row into cells
        func parseCells(_ line: String) -> [String] {
            var cells = line.components(separatedBy: "|")
            // Remove leading/trailing empty strings from outer pipes
            if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                cells.removeFirst()
            }
            if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                cells.removeLast()
            }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // Check second line is a separator (contains only |, -, :, spaces)
        let separatorLine = lines[1].trimmingCharacters(in: .whitespaces)
        let isSeparator = separatorLine.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
        guard isSeparator else { return nil }

        let headers = parseCells(lines[0])
        guard !headers.isEmpty else { return nil }

        // Data rows: skip header (0) and separator (1)
        let rows = lines.dropFirst(2).map { parseCells($0) }

        return .table(headers: headers, rows: rows, index: index)
    }
}

// MARK: - Main component

/// Renders markdown text with support for code blocks, headings, tables, and inline markup.
///
/// Used instead of plain `Text()` in Chappie message bubbles.
///
/// TEXTKIT-RANGE FIX: blocks are parsed once in init and stored as a let constant.
/// Previously blocks was a computed var — recomputed on every render pass.
/// With 50 messages in VStack this caused 50 simultaneous parses on thread switch,
/// plus TextKit "bad range" warnings from unstable view identity.
struct MarkdownTextView: View {

    let text: String
    var textColor: Color = .primary
    var fontSize: CGFloat = 14

    // TEXTKIT-RANGE FIX: parse once, store stable result — not a computed var.
    // Computed var recomputed on every render pass, causing identity instability.
    private let blocks: [MarkdownBlock]

    init(text: String, textColor: Color = .primary, fontSize: CGFloat = 14) {
        self.text = text
        self.textColor = textColor
        self.fontSize = fontSize
        // Parse markdown once at init time — result is stable for this view instance.
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let rawText, _):
            InlineTextView(text: rawText, fontSize: fontSize, color: textColor)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let rawText, let level, _):
            headingView(text: rawText, level: level)

        case .codeBlock(let code, let language, _):
            CodeBlockView(code: code, language: language)

        case .divider:
            Divider()
                .padding(.vertical, 4)

        case .table(let headers, let rows, _):
            TableBlockView(headers: headers, rows: rows, fontSize: fontSize)
        }
    }

    // MARK: - Headings

    @ViewBuilder
    private func headingView(text: String, level: Int) -> some View {
        switch level {
        case 1:
            InlineTextView(text: text, fontSize: fontSize + 6, color: textColor)
                .fontWeight(.bold)
                .padding(.top, 4)
        case 2:
            InlineTextView(text: text, fontSize: fontSize + 3, color: textColor)
                .fontWeight(.semibold)
                .padding(.top, 2)
        default:
            InlineTextView(text: text, fontSize: fontSize + 1, color: textColor)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Table block

/// Renders a markdown table with header row and data rows.
///
/// DESIGN:
/// - Header row: bold, slightly darker background
/// - Data rows: alternating subtle background for readability
/// - Borders: 1pt lines using system separator color
/// - Inline markup in cells: bold, inline code supported via InlineTextView
///
/// PERFORMANCE FIX (TABLE LAYOUT):
/// Vertical column dividers previously used Rectangle().frame(maxHeight: .infinity).
/// This forces SwiftUI into a two-pass layout: first measure all cells, then stretch
/// the rectangle to match the tallest cell. With multiple tables in the chat this
/// cascades into a layout storm on every scroll event, making the UI unresponsive.
/// Fix: replaced with a plain Color fill on a fixed-width frame — single-pass layout.
/// The column separator is now drawn as a colored 1pt-wide column inside the HStack,
/// sized naturally by the row height without triggering measurement passes.
private struct TableBlockView: View {

    let headers: [String]
    let rows: [[String]]
    let fontSize: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var borderColor: Color {
        colorScheme == .dark
            ? Color(white: 0.3)
            : Color(white: 0.75)
    }

    private var headerBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.18)
            : Color(white: 0.93)
    }

    private var rowBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.13)
            : Color(white: 0.98)
    }

    private var altRowBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.16)
            : Color(white: 0.955)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            tableRow(cells: headers, isHeader: true, background: headerBackground)

            Divider()
                .background(borderColor)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                tableRow(
                    cells: row,
                    isHeader: false,
                    background: idx % 2 == 0 ? rowBackground : altRowBackground
                )
                if idx < rows.count - 1 {
                    Divider()
                        .background(borderColor)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func tableRow(cells: [String], isHeader: Bool, background: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(paddedCells(cells).enumerated()), id: \.offset) { idx, cell in
                InlineTextView(
                    text: cell,
                    fontSize: fontSize - 1,
                    color: .primary
                )
                .fontWeight(isHeader ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

                // PERFORMANCE FIX: replaced Rectangle().frame(maxHeight: .infinity)
                // with a fixed-size borderColor column.
                // maxHeight: .infinity forced two-pass layout on every row —
                // SwiftUI had to measure all cells before stretching the divider.
                // A plain fixed-width Color view is single-pass: no measurement needed.
                if idx < headers.count - 1 {
                    borderColor
                        .frame(width: 1)
                }
            }
        }
        .background(background)
    }

    /// Pads or trims a row to match the header column count.
    ///
    /// Handles malformed tables where rows have fewer or more cells than headers.
    private func paddedCells(_ cells: [String]) -> [String] {
        let count = headers.count
        if cells.count >= count {
            return Array(cells.prefix(count))
        }
        return cells + Array(repeating: "", count: count - cells.count)
    }
}

// MARK: - Inline text

/// Renders a string with inline markup (**bold**, *italic*, `code`).
///
/// WHY A SEPARATE VIEW (not a function returning Text):
/// In macOS 26 the `+` operator for Text is deprecated — Apple recommends
/// `Text("\(Text(...).bold())")` string interpolation. But this approach
/// doesn't support arbitrary number of segments in a loop.
///
/// SOLUTION: use AttributedString with explicit font attributes.
/// This is the only reliable way to mix bold/italic/monospaced in one line
/// without deprecated API in macOS 26.
///
/// PERFORMANCE FIX (ATTRIBUTED STRING CACHING):
/// Previously buildAttributedString() was called inside body on every render pass.
/// For a table with 9 rows × 3 cols that means 27 AttributedString builds per
/// layout pass — and SwiftUI can trigger dozens of layout passes per scroll event.
/// Fix: AttributedString is computed once in init() and stored as a let constant.
/// body simply reads the pre-built value — zero allocation on subsequent renders.
private struct InlineTextView: View {

    let text: String
    let fontSize: CGFloat
    let color: Color

    // PERFORMANCE FIX: computed once in init, never recomputed on render.
    private let attributedString: AttributedString

    init(text: String, fontSize: CGFloat, color: Color) {
        self.text = text
        self.fontSize = fontSize
        self.color = color
        // Build once — stable for the lifetime of this view instance.
        self.attributedString = InlineTextView.buildAttributedString(text: text, fontSize: fontSize)
    }

    var body: some View {
        Text(attributedString)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }

    /// Builds an AttributedString with inline markup.
    ///
    /// Processing order matters: ** before *, so **bold** isn't confused with *italic*.
    /// Static method — no implicit self capture, safe to call from init.
    private static func buildAttributedString(text: String, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        var remaining = text

        while !remaining.isEmpty {

            // --- Bold: **text**
            if let openRange = remaining.range(of: "**"),
               let closeRange = remaining.range(of: "**", range: openRange.upperBound..<remaining.endIndex) {

                // Add text BEFORE marker as plain
                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                }

                // Add bold text
                let boldText = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                var seg = AttributedString(boldText)
                seg.font = .system(size: fontSize, weight: .bold)
                result.append(seg)

                remaining = String(remaining[closeRange.upperBound...])
                continue
            }

            // --- Inline code: `code`
            if let openRange = remaining.range(of: "`"),
               let closeRange = remaining.range(of: "`", range: openRange.upperBound..<remaining.endIndex) {

                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                }

                let codeText = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                var seg = AttributedString(codeText)
                // Monospaced font, slightly smaller — standard for inline code
                seg.font = .system(size: fontSize - 1, design: .monospaced)
                result.append(seg)

                remaining = String(remaining[closeRange.upperBound...])
                continue
            }

            // --- Italic: *text* (single asterisk only)
            if let openRange = remaining.range(of: "*"),
               let closeRange = remaining.range(of: "*", range: openRange.upperBound..<remaining.endIndex) {

                // Make sure this is not ** (double)
                let nextIdx = remaining.index(after: openRange.lowerBound)
                if nextIdx < remaining.endIndex && remaining[nextIdx] == "*" {
                    // This is ** — add first char as plain and continue
                    var seg = AttributedString(String(remaining[remaining.startIndex...openRange.lowerBound]))
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                    remaining = String(remaining[nextIdx...])
                    continue
                }

                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                }

                let italicText = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                var seg = AttributedString(italicText)
                seg.font = Font.system(size: fontSize).italic()
                result.append(seg)

                remaining = String(remaining[closeRange.upperBound...])
                continue
            }

            // No markers — rest of text is plain
            var seg = AttributedString(remaining)
            seg.font = .system(size: fontSize)
            result.append(seg)
            break
        }

        return result
    }
}

// MARK: - Code block

/// Renders a code block in Xcode Intelligence Panel style.
///
/// DESIGN (inspired by Xcode 26 Intelligence):
/// - Adaptive background: dark (#1E1E1E) in Dark Mode, white (#FFFFFF) in Light Mode.
///   Mirrors Xcode behavior — editor theme follows system theme.
/// - Header: language label left, copy button right
/// - Font: SF Mono 12.5pt — Xcode standard
/// - Horizontal scroll for long lines
/// - Rounded corners 8pt — like macOS 26 cards
struct CodeBlockView: View {

    let code: String
    let language: String?

    @State private var copied = false

    // Read system theme — key mechanism for adaptation.
    // View automatically redraws on theme change.
    @Environment(\.colorScheme) private var colorScheme

    /// Select theme based on system appearance.
    private var theme: SyntaxTheme {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // --- Code block header ---
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.labelColor)
                    .padding(.leading, 12)

                Spacer()

                // Copy button — standard in GitHub, Notion, ChatGPT.
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copied ? "Скопировано" : "Копировать")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(copied
                        ? Color(red: 0.3, green: 0.75, blue: 0.3)
                        : theme.labelColor
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: copied)
            }
            .padding(.vertical, 4)
            .background(theme.headerBackground)
            .overlay(alignment: .bottom) {
                // Thin separator line between header and code body
                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)
            }

            // --- Code block body ---
            // Horizontal ScrollView for long lines — IDE standard.
            ScrollView(.horizontal, showsIndicators: false) {
                SyntaxHighlightedText(code: code, language: language)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(4)
                    .padding(12)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .background(theme.background)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { copied = false }
        }
    }
}

// MARK: - Swift syntax highlighting

/// Renders code with basic Swift syntax highlighting.
///
/// THEME ADAPTATION:
/// Reads colorScheme from environment and selects the SyntaxTheme palette.
/// Light = Xcode Default Light, Dark = Xcode Default Dark.
///
/// TEXTKIT-RANGE FIX (unicode index safety):
/// All applyXxx methods previously used String.Index ↔ AttributedString.Index
/// conversion without guarding against unicode boundary mismatches.
/// Cyrillic, emoji, and other multi-byte characters cause String.Index positions
/// to not align with AttributedString.Index — direct force-application crashes TextKit.
/// Fix: every Range(range, in: attrStr) conversion is guarded with optional binding.
/// If the conversion fails (unicode mismatch), the coloring is simply skipped — safe.
private struct SyntaxHighlightedText: View {

    let code: String
    let language: String?

    // Read theme from environment — passed automatically from parent CodeBlockView
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SyntaxTheme {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        if language?.lowercased() == "swift" {
            Text(highlightSwift(code))
        } else {
            // Unknown language — use plain text color from theme
            Text(code)
                .foregroundStyle(theme.plainText)
        }
    }

    private func highlightSwift(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        // Base color — plain text from current theme
        result.foregroundColor = theme.plainText

        let keywords = [
            "func", "var", "let", "class", "struct", "enum", "protocol",
            "extension", "import", "return", "if", "else", "guard", "switch",
            "case", "default", "for", "while", "do", "try", "catch", "throw",
            "throws", "async", "await", "actor", "nonisolated", "isolated",
            "public", "private", "internal", "fileprivate", "open",
            "static", "final", "override", "mutating", "nonmutating",
            "init", "deinit", "self", "super", "nil", "true", "false",
            "in", "is", "as", "where", "some", "any", "typealias",
            "@MainActor", "@Observable", "@State", "@Binding", "@Environment",
            "@Published", "@StateObject", "@ObservedObject", "Task", "MainActor"
        ]

        for keyword in keywords {
            applyColor(theme.keyword, toWord: keyword, in: &result)
        }

        applyTypeHighlighting(color: theme.type_, in: &result)
        applyStringHighlighting(color: theme.string, in: &result)
        applyNumberHighlighting(color: theme.number, in: &result)
        // Comments last — override everything inside them
        applyCommentHighlighting(color: theme.comment, in: &result)

        return result
    }

    /// Applies color to exact word occurrences respecting word boundaries.
    ///
    /// TEXTKIT-RANGE FIX: Range(range, in: attrStr) is guarded with optional binding.
    /// String.Index and AttributedString.Index diverge on unicode (Cyrillic, emoji).
    /// If conversion fails, coloring is skipped — no crash, no "bad range" warning.
    private func applyColor(_ color: Color, toWord word: String, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var searchRange = str.startIndex..<str.endIndex

        while let range = str.range(of: word, options: .literal, range: searchRange) {
            let isBoundedLeft = range.lowerBound == str.startIndex
                || (!str[str.index(before: range.lowerBound)].isLetter
                    && str[str.index(before: range.lowerBound)] != "_")
            let isBoundedRight = range.upperBound == str.endIndex
                || (!str[range.upperBound].isLetter
                    && str[range.upperBound] != "_"
                    && !str[range.upperBound].isNumber)

            if isBoundedLeft && isBoundedRight,
               let attrRange = Range(range, in: attrStr) {
                // Guard: only apply if index conversion succeeded (unicode-safe)
                attrStr[attrRange].foregroundColor = color
            }
            searchRange = range.upperBound..<str.endIndex
        }
    }

    /// Highlights types (words starting with uppercase).
    ///
    /// TEXTKIT-RANGE FIX: Range conversion guarded with optional binding.
    private func applyTypeHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex
        while i < str.endIndex {
            guard str[i].isUppercase else {
                i = str.index(after: i)
                continue
            }
            var j = i
            while j < str.endIndex && (str[j].isLetter || str[j].isNumber || str[j] == "_") {
                j = str.index(after: j)
            }
            if str.distance(from: i, to: j) > 1,
               let attrRange = Range(i..<j, in: attrStr) {
                // Guard: only apply if index conversion succeeded (unicode-safe)
                attrStr[attrRange].foregroundColor = color
            }
            i = j < str.endIndex ? j : str.endIndex
        }
    }

    /// Highlights string literals (in double quotes).
    ///
    /// TEXTKIT-RANGE FIX: Range conversion guarded with optional binding.
    private func applyStringHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex
        var inString = false
        var stringStart = str.startIndex

        while i < str.endIndex {
            if str[i] == "\"" && !inString {
                inString = true
                stringStart = i
            } else if str[i] == "\"" && inString {
                inString = false
                let end = str.index(after: i)
                if let attrRange = Range(stringStart..<end, in: attrStr) {
                    // Guard: only apply if index conversion succeeded (unicode-safe)
                    attrStr[attrRange].foregroundColor = color
                }
            } else if str[i] == "\\" && inString {
                i = str.index(after: i)
                if i >= str.endIndex { break }
            }
            i = str.index(after: i)
        }
    }

    /// Highlights numeric literals.
    ///
    /// TEXTKIT-RANGE FIX: Range conversion guarded with optional binding.
    private func applyNumberHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex

        while i < str.endIndex {
            guard str[i].isNumber else {
                i = str.index(after: i)
                continue
            }
            let isBoundedLeft = i == str.startIndex
                || (!str[str.index(before: i)].isLetter && str[str.index(before: i)] != "_")
            if !isBoundedLeft {
                i = str.index(after: i)
                continue
            }
            var j = i
            while j < str.endIndex && (str[j].isNumber || str[j] == "." || str[j] == "_") {
                j = str.index(after: j)
            }
            if let attrRange = Range(i..<j, in: attrStr) {
                // Guard: only apply if index conversion succeeded (unicode-safe)
                attrStr[attrRange].foregroundColor = color
            }
            i = j < str.endIndex ? j : str.endIndex
        }
    }

    /// Highlights single-line comments (// ...).
    ///
    /// TEXTKIT-RANGE FIX: Range conversion guarded with optional binding.
    private func applyCommentHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex

        while i < str.endIndex {
            guard i < str.index(before: str.endIndex) else { break }
            let next = str.index(after: i)
            if str[i] == "/" && str[next] == "/" {
                var j = next
                while j < str.endIndex && str[j] != "\n" {
                    j = str.index(after: j)
                }
                if let attrRange = Range(i..<j, in: attrStr) {
                    // Guard: only apply if index conversion succeeded (unicode-safe)
                    attrStr[attrRange].foregroundColor = color
                }
                i = j < str.endIndex ? str.index(after: j) : str.endIndex
            } else {
                i = str.index(after: i)
            }
        }
    }
}

// MARK: - Preview

#Preview("Markdown with tables — Dark") {
    ScrollView {
        MarkdownTextView(text: """
        ## 🔴 Высокий приоритет

        | # | Задача | Effort |
        |---|--------|--------|
        | 1 | **Multi-language syntax highlighting** — Highlightr, 185 языков | small |
        | 2 | **Web Fetch Tool** — `fetch_url`, HTML→Markdown | medium |
        | 3 | **Переименование в ChappieAI** — bundle ID, display name | medium |

        ## 🟡 Средний приоритет

        | # | Задача | Effort |
        |---|--------|--------|
        | 1 | **Universal balance & cost** — топ-10 провайдеров | medium |
        | 2 | **Фоновая картинка** — нейтральная + выбор из ФС | small |
        | 3 | **Office форматы** — .docx, .xlsx, .pdf | large |

        ## 🟢 Низкий приоритет

        | # | Задача | Effort |
        |---|--------|--------|
        | 1 | **Spell check** — нативный spellcheck в поле ввода | small |
        """)
        .padding()
    }
    .frame(width: 600, height: 600)
    .background(Color(NSColor.windowBackgroundColor))
    .preferredColorScheme(.dark)
}

#Preview("Markdown with code — Light") {
    ScrollView {
        MarkdownTextView(text: """
        Here's how it works:

        ## Architecture

        Using the **MVVM** pattern with the `@Observable` macro.

        ```swift
        // Main ViewModel
        @Observable
        @MainActor
        final class ChappieViewModel {
            var messages: [ChatMessage] = []
            var isThinking: Bool = false
        }
        ```
        """)
        .padding()
    }
    .frame(width: 600, height: 400)
    .background(Color(NSColor.windowBackgroundColor))
    .preferredColorScheme(.light)
}
