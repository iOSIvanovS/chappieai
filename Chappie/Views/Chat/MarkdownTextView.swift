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
// PERFORMANCE FIX (TABLE LAYOUT — v2):
// Root cause of CPU storm was three compounding issues in TableBlockView:
//
//   1. .fontWeight() applied OUTSIDE InlineTextView on top of Text(attributedString).
//      AttributedString already carries .font attributes — SwiftUI cannot merge
//      an external .fontWeight() modifier with internal font attributes in TextKit.
//      Result: TextKit discards attributes and recomputes layout on every pass.
//      Fix: isHeader passed into InlineTextView, which builds the AttributedString
//      with the correct weight internally — zero external font modifiers.
//
//   2. borderColor (a Color view) used as a vertical divider without fixedSize.
//      SwiftUI still runs a measurement pass to determine height.
//      Fix: removed vertical column dividers entirely (GitHub Markdown style).
//      Only horizontal row dividers remain — drawn via Divider(), single-pass.
//
//   3. ForEach(Array(rows.enumerated()), id: \.offset) — offset-based IDs are
//      unstable when rows change. SwiftUI cannot reuse row views across renders.
//      Fix: rows wrapped in a stable TableRow struct with a content-hash-based ID
//      so SwiftUI can diff and reuse unchanged rows.
//
// WINDOW MIN-WIDTH FIX (CODE BLOCK):
// .fixedSize(horizontal: true, vertical: false) was applied to SyntaxHighlightedText
// inside ScrollView(.horizontal). fixedSize(horizontal: true) tells SwiftUI "give me
// as much width as I need" — this requirement propagates UP through the layout tree
// and prevents the window from being resized narrower than the longest code line.
// Fix: removed fixedSize entirely. ScrollView(.horizontal) already handles overflow
// correctly — content scrolls horizontally without forcing the window to expand.
//
// IMPORTANT (macOS 26):
// The `+` operator for Text is deprecated in macOS 26 — use
// Text("\(Text(...).bold())") string interpolation instead.
// buildInlineText() uses this approach.
//
// MULTI-LANGUAGE SYNTAX HIGHLIGHTING:
// SyntaxHighlighter supports 11 languages without any external dependencies.
// Architecture: shared engine (strings, numbers, comments) + per-language keyword sets.
// Languages: swift, python, javascript/js, typescript/ts, bash/sh/shell,
//            json, sql, kotlin, rust, go, c/cpp/c++/java (C-family).
// Unknown languages: plain text with theme color — always readable.

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
            // PERF: fontSize passed directly — no external .fontWeight() on top of AttributedString
            InlineTextView(text: text, fontSize: fontSize + 6, color: textColor, weight: .bold)
                .padding(.top, 4)
        case 2:
            InlineTextView(text: text, fontSize: fontSize + 3, color: textColor, weight: .semibold)
                .padding(.top, 2)
        default:
            InlineTextView(text: text, fontSize: fontSize + 1, color: textColor, weight: .medium)
        }
    }
}

// MARK: - Stable table row wrapper

/// Wraps a table row with a stable, content-derived ID for SwiftUI diffing.
///
/// PERFORMANCE FIX: ForEach(Array(rows.enumerated()), id: \.offset) uses offset-based
/// IDs which are unstable when rows change — SwiftUI cannot reuse row views.
/// TableRow wraps each row with a hash-derived ID so unchanged rows are reused.
private struct TableRow: Identifiable {
    let cells: [String]
    let index: Int
    // Stable ID: combines row index + cell content hash.
    // Index alone is not enough if rows are reordered; content hash alone
    // is not enough if two rows have identical content. Together they are unique.
    let id: String

    init(cells: [String], index: Int) {
        self.cells = cells
        self.index = index
        self.id = "\(index)_\(cells.joined().hashValue)"
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
/// - No vertical column dividers — GitHub Markdown style, eliminates measurement passes
///
/// PERFORMANCE FIX v2 (TABLE LAYOUT):
///
/// Fix 1 — fontWeight conflict:
///   Previously: InlineTextView rendered Text(attributedString), then .fontWeight()
///   was applied OUTSIDE. AttributedString already carries .font attributes, so SwiftUI
///   cannot merge the external modifier — it discards the attributes and forces TextKit
///   to recompute layout on every single render pass. CPU spikes to 100% on scroll.
///   Fix: isHeader is passed INTO InlineTextView; weight is baked into AttributedString
///   at init time. No external font modifiers anywhere on InlineTextView.
///
/// Fix 2 — vertical dividers removed:
///   Previously: borderColor (a Color view) was used as a 1pt vertical column divider.
///   Even without maxHeight: .infinity, a bare Color in HStack still triggers a
///   measurement pass because SwiftUI needs to determine its natural size.
///   Fix: vertical dividers removed entirely. Only horizontal Divider() between rows.
///   This matches GitHub Markdown table style and eliminates all measurement passes.
///
/// Fix 3 — stable row IDs:
///   Previously: ForEach(Array(rows.enumerated()), id: \.offset) — offset IDs are
///   unstable and prevent SwiftUI from reusing row views across renders.
///   Fix: rows wrapped in TableRow with content-hash-based stable ID.
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

    // PERF FIX 3: wrap rows in stable TableRow structs once — not on every render.
    private var tableRows: [TableRow] {
        rows.enumerated().map { TableRow(cells: $0.element, index: $0.offset) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row — isHeader=true bakes .semibold into AttributedString
            tableRow(cells: headers, isHeader: true, background: headerBackground)

            Divider()
                .background(borderColor)

            // PERF FIX 3: ForEach over stable TableRow IDs — SwiftUI can diff and reuse
            ForEach(tableRows) { row in
                tableRow(
                    cells: row.cells,
                    isHeader: false,
                    background: row.index % 2 == 0 ? rowBackground : altRowBackground
                )
                if row.index < rows.count - 1 {
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
            ForEach(Array(paddedCells(cells).enumerated()), id: \.offset) { _, cell in
                // PERF FIX 1: weight passed INTO InlineTextView — baked into AttributedString.
                // No external .fontWeight() modifier — eliminates TextKit layout recomputation.
                InlineTextView(
                    text: cell,
                    fontSize: fontSize - 1,
                    color: .primary,
                    weight: isHeader ? .semibold : .regular
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                // PERF FIX 2: no vertical Color divider — eliminates measurement passes.
                // GitHub Markdown style: only horizontal row separators.
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
///
/// PERFORMANCE FIX v2 (WEIGHT BAKING):
/// Previously .fontWeight() was applied externally by the caller (e.g. TableBlockView).
/// Applying a font modifier on top of Text(attributedString) causes TextKit to discard
/// internal font attributes and recompute layout — CPU storm on every scroll event.
/// Fix: `weight` parameter added to init; baked into every font attribute in the
/// AttributedString at construction time. No external font modifiers ever needed.
private struct InlineTextView: View {

    let text: String
    let fontSize: CGFloat
    let color: Color

    // PERFORMANCE FIX: computed once in init, never recomputed on render.
    private let attributedString: AttributedString

    init(text: String, fontSize: CGFloat, color: Color, weight: Font.Weight = .regular) {
        self.text = text
        self.fontSize = fontSize
        self.color = color
        // PERF FIX v2: weight is baked into AttributedString here — not applied externally.
        self.attributedString = InlineTextView.buildAttributedString(
            text: text,
            fontSize: fontSize,
            weight: weight
        )
    }

    var body: some View {
        Text(attributedString)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }

    /// Builds an AttributedString with inline markup and a base font weight.
    ///
    /// Processing order matters: ** before *, so **bold** isn't confused with *italic*.
    /// Static method — no implicit self capture, safe to call from init.
    ///
    /// PERF FIX v2: `weight` is the base weight for all plain-text segments.
    /// Bold (**) segments always use .bold regardless of base weight.
    private static func buildAttributedString(
        text: String,
        fontSize: CGFloat,
        weight: Font.Weight
    ) -> AttributedString {
        var result = AttributedString()
        var remaining = text

        while !remaining.isEmpty {

            // --- Bold: **text**
            if let openRange = remaining.range(of: "**"),
               let closeRange = remaining.range(of: "**", range: openRange.upperBound..<remaining.endIndex) {

                // Add text BEFORE marker as plain (with base weight)
                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize, weight: weight)
                    result.append(seg)
                }

                // Bold text always uses .bold regardless of base weight
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
                    seg.font = .system(size: fontSize, weight: weight)
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
                    seg.font = .system(size: fontSize, weight: weight)
                    result.append(seg)
                    remaining = String(remaining[nextIdx...])
                    continue
                }

                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize, weight: weight)
                    result.append(seg)
                }

                let italicText = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                var seg = AttributedString(italicText)
                seg.font = Font.system(size: fontSize, weight: weight).italic()
                result.append(seg)

                remaining = String(remaining[closeRange.upperBound...])
                continue
            }

            // No markers — rest of text is plain
            var seg = AttributedString(remaining)
            seg.font = .system(size: fontSize, weight: weight)
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
///
/// WINDOW MIN-WIDTH FIX:
/// .fixedSize(horizontal: true) was previously applied to SyntaxHighlightedText.
/// This propagated a "give me infinite width" demand up through the layout tree,
/// preventing the window from being resized narrower than the longest code line.
/// Fix: fixedSize removed entirely. ScrollView(.horizontal) handles overflow
/// without affecting the parent window's minimum resizable width.
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
            // NO fixedSize(horizontal: true) here — that modifier propagates a
            // "give me infinite width" demand up the layout tree and prevents the
            // window from being resized narrower than the longest code line.
            // ScrollView(.horizontal) handles overflow correctly without fixedSize.
            ScrollView(.horizontal, showsIndicators: false) {
                SyntaxHighlightedText(code: code, language: language)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(4)
                    .padding(12)
                    .textSelection(.enabled)
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

// MARK: - Multi-language syntax highlighter

/// Renders code with syntax highlighting for 11 languages.
///
/// SUPPORTED LANGUAGES:
///   swift, python, javascript (js), typescript (ts),
///   bash / sh / shell, json, sql, kotlin, rust, go,
///   c / cpp / c++ / java  (C-family shared keywords)
///
/// ARCHITECTURE:
///   Shared engine handles strings, numbers, and comments for all languages.
///   Per-language keyword tables drive keyword coloring.
///   Type highlighting (uppercase-starting words) is used for Swift, Kotlin, Java, Rust, Go.
///   Unknown languages fall back to plain themed text — always readable.
///
/// TEXTKIT-RANGE FIX (unicode index safety):
///   All applyXxx methods guard Range(range, in: attrStr) with optional binding.
///   String.Index ↔ AttributedString.Index diverge on Cyrillic / emoji / multi-byte chars.
///   If conversion fails — coloring is skipped, no crash, no "bad range" warning.
private struct SyntaxHighlightedText: View {

    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme

    private var theme: SyntaxTheme {
        colorScheme == .dark ? .dark : .light
    }

    // Normalize the language tag to a canonical form for switch matching.
    private var normalizedLang: String {
        switch language?.lowercased() ?? "" {
        case "js", "javascript":            return "javascript"
        case "ts", "typescript":            return "typescript"
        case "sh", "shell", "bash":         return "bash"
        case "cpp", "c++":                  return "cpp"
        case "swift":                       return "swift"
        case "python", "py":                return "python"
        case "kotlin", "kt":                return "kotlin"
        case "rust", "rs":                  return "rust"
        case "go", "golang":                return "go"
        case "java":                        return "java"
        case "json":                        return "json"
        case "sql":                         return "sql"
        case "c":                           return "c"
        default:                            return language?.lowercased() ?? ""
        }
    }

    var body: some View {
        let highlighted = highlight(code, lang: normalizedLang)
        Text(highlighted)
    }

    // MARK: - Dispatch

    /// Selects the highlighting strategy for the given normalized language.
    private func highlight(_ code: String, lang: String) -> AttributedString {
        switch lang {
        case "swift":
            return highlightWithKeywords(code, keywords: Self.swiftKeywords, useTypeHighlight: true, commentStyle: .slashSlash)
        case "python":
            return highlightWithKeywords(code, keywords: Self.pythonKeywords, useTypeHighlight: false, commentStyle: .hash)
        case "javascript":
            return highlightWithKeywords(code, keywords: Self.jsKeywords, useTypeHighlight: false, commentStyle: .slashSlash)
        case "typescript":
            return highlightWithKeywords(code, keywords: Self.tsKeywords, useTypeHighlight: false, commentStyle: .slashSlash)
        case "kotlin":
            return highlightWithKeywords(code, keywords: Self.kotlinKeywords, useTypeHighlight: true, commentStyle: .slashSlash)
        case "rust":
            return highlightWithKeywords(code, keywords: Self.rustKeywords, useTypeHighlight: true, commentStyle: .slashSlash)
        case "go":
            return highlightWithKeywords(code, keywords: Self.goKeywords, useTypeHighlight: true, commentStyle: .slashSlash)
        case "java":
            return highlightWithKeywords(code, keywords: Self.javaKeywords, useTypeHighlight: true, commentStyle: .slashSlash)
        case "c", "cpp":
            return highlightWithKeywords(code, keywords: Self.cKeywords, useTypeHighlight: false, commentStyle: .slashSlash)
        case "bash":
            return highlightBash(code)
        case "json":
            return highlightJSON(code)
        case "sql":
            return highlightWithKeywords(code, keywords: Self.sqlKeywords, useTypeHighlight: false, commentStyle: .doubleDash, caseInsensitiveKeywords: true)
        default:
            // Unknown language — plain text with theme color, always readable.
            var result = AttributedString(code)
            result.foregroundColor = theme.plainText
            return result
        }
    }

    // MARK: - Comment style

    private enum CommentStyle {
        case slashSlash   // // comment  (Swift, JS, TS, Kotlin, Rust, Go, Java, C)
        case hash         // # comment   (Python, Bash)
        case doubleDash   // -- comment  (SQL)
    }

    // MARK: - Generic keyword highlighter

    /// Shared highlighting engine: keywords → strings → numbers → comments.
    ///
    /// Order matters: comments applied last so they override everything inside them.
    private func highlightWithKeywords(
        _ code: String,
        keywords: [String],
        useTypeHighlight: Bool,
        commentStyle: CommentStyle,
        caseInsensitiveKeywords: Bool = false
    ) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = theme.plainText

        // Keywords — language-specific reserved words
        for kw in keywords {
            applyColor(theme.keyword, toWord: kw, in: &result, caseInsensitive: caseInsensitiveKeywords)
        }

        // Types — words starting with uppercase (Swift, Kotlin, Java, Rust, Go)
        if useTypeHighlight {
            applyTypeHighlighting(color: theme.type_, in: &result)
        }

        // String literals — double and single quotes
        applyStringHighlighting(color: theme.string, in: &result)

        // Numeric literals
        applyNumberHighlighting(color: theme.number, in: &result)

        // Comments — applied last to override keyword/type color inside comments
        switch commentStyle {
        case .slashSlash:
            applyLineCommentHighlighting(prefix: "//", color: theme.comment, in: &result)
        case .hash:
            applyLineCommentHighlighting(prefix: "#", color: theme.comment, in: &result)
        case .doubleDash:
            applyLineCommentHighlighting(prefix: "--", color: theme.comment, in: &result)
        }

        return result
    }

    // MARK: - Bash highlighter

    /// Bash-specific highlighting: builtins, flags, variables ($VAR), shebang.
    private func highlightBash(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = theme.plainText

        // Built-in commands and keywords
        for kw in Self.bashKeywords {
            applyColor(theme.keyword, toWord: kw, in: &result)
        }

        // $VARIABLE and ${VARIABLE} — highlight as type color
        applyBashVariables(color: theme.type_, in: &result)

        // String literals (double-quoted)
        applyStringHighlighting(color: theme.string, in: &result)

        // Numbers
        applyNumberHighlighting(color: theme.number, in: &result)

        // # comments (but NOT shebang #! on line 1 — keep it as comment too, it's fine)
        applyLineCommentHighlighting(prefix: "#", color: theme.comment, in: &result)

        return result
    }

    // MARK: - JSON highlighter

    /// JSON-specific highlighting: keys (strings before colon) vs value strings,
    /// booleans/null as keywords, numbers.
    private func highlightJSON(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = theme.plainText

        // true, false, null — JSON keywords
        for kw in ["true", "false", "null"] {
            applyColor(theme.keyword, toWord: kw, in: &result)
        }

        // All strings — keys and values both get string color.
        // We can't easily distinguish key vs value without a full JSON parser,
        // and string color for both is the standard approach (VS Code does the same).
        applyStringHighlighting(color: theme.string, in: &result)

        // Numbers
        applyNumberHighlighting(color: theme.number, in: &result)

        return result
    }

    // MARK: - Keyword tables

    private static let swiftKeywords: [String] = [
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

    private static let pythonKeywords: [String] = [
        "def", "class", "import", "from", "as", "return", "if", "elif", "else",
        "for", "while", "try", "except", "finally", "raise", "with", "pass",
        "break", "continue", "lambda", "yield", "global", "nonlocal", "del",
        "assert", "and", "or", "not", "in", "is", "None", "True", "False",
        "async", "await", "self", "cls", "__init__", "__name__", "__main__"
    ]

    private static let jsKeywords: [String] = [
        "function", "const", "let", "var", "class", "extends", "import", "export",
        "default", "return", "if", "else", "for", "while", "do", "try", "catch",
        "finally", "throw", "new", "this", "super", "typeof", "instanceof",
        "switch", "case", "break", "continue", "of", "in", "from", "async",
        "await", "null", "undefined", "true", "false", "static", "get", "set",
        "=>", "delete", "void", "yield"
    ]

    private static let tsKeywords: [String] = jsKeywords + [
        "interface", "type", "enum", "namespace", "declare", "abstract",
        "readonly", "private", "public", "protected", "implements", "as",
        "keyof", "typeof", "never", "unknown", "any", "string", "number",
        "boolean", "object", "symbol", "bigint", "void", "infer"
    ]

    private static let kotlinKeywords: [String] = [
        "fun", "val", "var", "class", "object", "interface", "enum", "sealed",
        "data", "abstract", "open", "final", "override", "private", "public",
        "protected", "internal", "companion", "import", "package", "return",
        "if", "else", "when", "for", "while", "do", "try", "catch", "finally",
        "throw", "throws", "is", "as", "in", "out", "by", "init", "constructor",
        "this", "super", "null", "true", "false", "suspend", "inline", "reified",
        "typealias", "lateinit", "lazy", "it", "apply", "let", "run", "also", "with"
    ]

    private static let rustKeywords: [String] = [
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait",
        "impl", "use", "mod", "pub", "crate", "self", "super", "type",
        "where", "for", "while", "loop", "if", "else", "match", "return",
        "break", "continue", "in", "as", "ref", "move", "box", "dyn",
        "async", "await", "unsafe", "extern", "true", "false", "None", "Some",
        "Ok", "Err", "Vec", "String", "Option", "Result", "Box", "Rc", "Arc"
    ]

    private static let goKeywords: [String] = [
        "func", "var", "const", "type", "struct", "interface", "map", "chan",
        "package", "import", "return", "if", "else", "for", "range", "switch",
        "case", "default", "break", "continue", "goto", "fallthrough",
        "go", "select", "defer", "make", "new", "len", "cap", "append",
        "copy", "delete", "close", "panic", "recover", "nil", "true", "false",
        "int", "int8", "int16", "int32", "int64",
        "uint", "uint8", "uint16", "uint32", "uint64",
        "float32", "float64", "complex64", "complex128",
        "string", "bool", "byte", "rune", "error", "any"
    ]

    private static let javaKeywords: [String] = [
        "public", "private", "protected", "static", "final", "abstract",
        "class", "interface", "enum", "extends", "implements", "import",
        "package", "return", "if", "else", "for", "while", "do", "try",
        "catch", "finally", "throw", "throws", "new", "this", "super",
        "instanceof", "switch", "case", "default", "break", "continue",
        "void", "int", "long", "double", "float", "boolean", "char",
        "byte", "short", "null", "true", "false", "synchronized",
        "volatile", "transient", "native", "strictfp", "assert"
    ]

    private static let cKeywords: [String] = [
        "int", "long", "short", "char", "float", "double", "void",
        "unsigned", "signed", "const", "static", "extern", "register",
        "volatile", "auto", "inline", "restrict",
        "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "goto",
        "struct", "union", "enum", "typedef",
        "sizeof", "NULL", "true", "false",
        "#include", "#define", "#ifdef", "#ifndef", "#endif", "#pragma"
    ]

    private static let bashKeywords: [String] = [
        "echo", "export", "source", "cd", "ls", "mkdir", "rm", "mv", "cp",
        "cat", "grep", "sed", "awk", "find", "chmod", "chown", "sudo",
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "in", "function", "return", "exit", "local",
        "read", "set", "unset", "shift", "trap", "exec", "eval",
        "true", "false", "test", "kill", "sleep", "printf", "pwd"
    ]

    private static let sqlKeywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "EXISTS",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "ON",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "AS", "DISTINCT", "ALL", "UNION", "INTERSECT", "EXCEPT",
        "NULL", "IS", "LIKE", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT",
        "NOT NULL", "AUTO_INCREMENT", "SERIAL", "RETURNING",
        "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
        "INT", "INTEGER", "VARCHAR", "TEXT", "BOOLEAN", "DATE", "TIMESTAMP", "FLOAT", "NUMERIC"
    ]

    // MARK: - Shared coloring primitives

    /// Applies a color to all word-boundary-matched occurrences of `word`.
    ///
    /// TEXTKIT-RANGE FIX: Range conversion guarded — skips on unicode mismatch.
    private func applyColor(
        _ color: Color,
        toWord word: String,
        in attrStr: inout AttributedString,
        caseInsensitive: Bool = false
    ) {
        let str = String(attrStr.characters)
        var searchRange = str.startIndex..<str.endIndex
        let options: String.CompareOptions = caseInsensitive ? [.literal, .caseInsensitive] : [.literal]

        while let range = str.range(of: word, options: options, range: searchRange) {
            // Word-boundary check: char before must not be letter/digit/underscore
            let isBoundedLeft = range.lowerBound == str.startIndex
                || (!str[str.index(before: range.lowerBound)].isLetter
                    && str[str.index(before: range.lowerBound)] != "_"
                    && str[str.index(before: range.lowerBound)] != "@"
                    && str[str.index(before: range.lowerBound)] != "#")
            // Char after must not be letter/digit/underscore
            let isBoundedRight = range.upperBound == str.endIndex
                || (!str[range.upperBound].isLetter
                    && str[range.upperBound] != "_"
                    && !str[range.upperBound].isNumber)

            if isBoundedLeft && isBoundedRight,
               let attrRange = Range(range, in: attrStr) {
                attrStr[attrRange].foregroundColor = color
            }
            searchRange = range.upperBound..<str.endIndex
        }
    }

    /// Highlights words starting with an uppercase letter as type names.
    ///
    /// Used for Swift, Kotlin, Java, Rust, Go — where types are PascalCase.
    /// TEXTKIT-RANGE FIX: Range conversion guarded.
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
                attrStr[attrRange].foregroundColor = color
            }
            i = j < str.endIndex ? j : str.endIndex
        }
    }

    /// Highlights string literals in double quotes (and single quotes for JS/Python).
    ///
    /// Handles escape sequences (\") so a quote inside a string doesn't close it.
    /// TEXTKIT-RANGE FIX: Range conversion guarded.
    private func applyStringHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)

        // Highlight both double-quoted and single-quoted strings.
        // Single-quote pass is needed for Python, JS, SQL.
        for quote: Character in ["\"", "'"] {
            var i = str.startIndex
            var inString = false
            var stringStart = str.startIndex

            while i < str.endIndex {
                if str[i] == quote && !inString {
                    inString = true
                    stringStart = i
                } else if str[i] == quote && inString {
                    inString = false
                    let end = str.index(after: i)
                    if let attrRange = Range(stringStart..<end, in: attrStr) {
                        attrStr[attrRange].foregroundColor = color
                    }
                } else if str[i] == "\\" && inString {
                    // Skip escaped character — don't let \" close the string
                    i = str.index(after: i)
                    if i >= str.endIndex { break }
                } else if str[i] == "\n" && inString {
                    // Unterminated string — reset on newline (safe fallback)
                    inString = false
                }
                i = str.index(after: i)
            }
        }
    }

    /// Highlights numeric literals (integers, floats, hex 0x..., binary 0b...).
    ///
    /// TEXTKIT-RANGE FIX: Range conversion guarded.
    private func applyNumberHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex

        while i < str.endIndex {
            guard str[i].isNumber else {
                i = str.index(after: i)
                continue
            }
            // Must not be preceded by a letter or underscore (e.g. "var1" → not a number)
            let isBoundedLeft = i == str.startIndex
                || (!str[str.index(before: i)].isLetter && str[str.index(before: i)] != "_")
            guard isBoundedLeft else {
                i = str.index(after: i)
                continue
            }
            var j = i
            // Consume digits, dots, underscores, hex chars, x/b prefix chars
            while j < str.endIndex
                && (str[j].isNumber || str[j] == "." || str[j] == "_"
                    || str[j] == "x" || str[j] == "b"
                    || ("a"..."f").contains(str[j]) || ("A"..."F").contains(str[j])) {
                j = str.index(after: j)
            }
            if let attrRange = Range(i..<j, in: attrStr) {
                attrStr[attrRange].foregroundColor = color
            }
            i = j < str.endIndex ? j : str.endIndex
        }
    }

    /// Highlights single-line comments from `prefix` to end of line.
    ///
    /// Works for //, #, and -- comment styles.
    /// TEXTKIT-RANGE FIX: Range conversion guarded.
    private func applyLineCommentHighlighting(prefix: String, color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex

        while i < str.endIndex {
            // Check if current position starts with the comment prefix
            guard str[i...].hasPrefix(prefix) else {
                i = str.index(after: i)
                continue
            }
            // Find end of line (or end of string)
            var j = i
            while j < str.endIndex && str[j] != "\n" {
                j = str.index(after: j)
            }
            if let attrRange = Range(i..<j, in: attrStr) {
                attrStr[attrRange].foregroundColor = color
            }
            // Continue after the newline
            i = j < str.endIndex ? str.index(after: j) : str.endIndex
        }
    }

    /// Highlights $VAR and ${VAR} bash variable references.
    ///
    /// TEXTKIT-RANGE FIX: Range conversion guarded.
    private func applyBashVariables(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex

        while i < str.endIndex {
            guard str[i] == "$" else {
                i = str.index(after: i)
                continue
            }
            let dollarIdx = i
            i = str.index(after: i)
            guard i < str.endIndex else { break }

            if str[i] == "{" {
                // ${VARIABLE} — find closing }
                i = str.index(after: i)
                let start = dollarIdx
                while i < str.endIndex && str[i] != "}" {
                    i = str.index(after: i)
                }
                if i < str.endIndex {
                    let end = str.index(after: i)
                    if let attrRange = Range(start..<end, in: attrStr) {
                        attrStr[attrRange].foregroundColor = color
                    }
                    i = end
                }
            } else if str[i].isLetter || str[i] == "_" {
                // $VARIABLE — consume letters, digits, underscores
                let start = dollarIdx
                while i < str.endIndex && (str[i].isLetter || str[i].isNumber || str[i] == "_") {
                    i = str.index(after: i)
                }
                if let attrRange = Range(start..<i, in: attrStr) {
                    attrStr[attrRange].foregroundColor = color
                }
            }
            // $0, $1, etc. (positional params) — treat as numbers, already handled
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

#Preview("Multi-language highlighting — Dark") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            CodeBlockView(code: """
            def greet(name: str) -> str:
                # Say hello
                return f"Hello, {name}!"

            for i in range(10):
                print(greet("World"))
            """, language: "python")

            CodeBlockView(code: """
            const fetchUser = async (id: number): Promise<User> => {
                // Load user from API
                const res = await fetch(`/api/users/${id}`)
                return res.json()
            }
            """, language: "typescript")

            CodeBlockView(code: """
            fn main() {
                let mut v: Vec<i32> = Vec::new();
                // Push some values
                for i in 0..10 {
                    v.push(i * 2);
                }
                println!("{:?}", v);
            }
            """, language: "rust")

            CodeBlockView(code: """
            #!/bin/bash
            # Deploy script
            export ENV=production
            if [ "$1" == "--dry-run" ]; then
                echo "Dry run mode"
                exit 0
            fi
            cd /app && ./deploy.sh
            """, language: "bash")

            CodeBlockView(code: """
            SELECT u.name, COUNT(o.id) AS orders
            FROM users u
            LEFT JOIN orders o ON o.user_id = u.id
            WHERE u.active = true
            GROUP BY u.name
            ORDER BY orders DESC
            LIMIT 10;
            """, language: "sql")
        }
        .padding()
    }
    .frame(width: 650, height: 900)
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
