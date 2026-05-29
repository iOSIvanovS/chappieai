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
// CodeBlockView uses @Environment(\.colorScheme) and passes NSColor-based
// SyntaxNSTheme directly into SyntaxHighlightedText.
// SyntaxHighlightedText is an NSViewRepresentable wrapping NSTextView —
// this guarantees that NSAttributedString colors are always rendered correctly,
// regardless of SwiftUI's foregroundStyle/foregroundColor attribute handling quirks.
//
// WHY NSViewRepresentable FOR SYNTAX HIGHLIGHTING:
// SwiftUI Text(AttributedString) with .foregroundColor set on AttributedString
// segments is unreliable on macOS — the color is silently ignored when the
// Text is nested inside ScrollView or certain container views. This is a known
// SwiftUI/TextKit integration issue. NSTextView renders NSAttributedString with
// NSColor directly — always correct, no SwiftUI attribute scope confusion.
//
// BAD RANGE FIX (TEXTKIT-RANGE):
// Previously: String.Index ↔ AttributedString.Index mismatch on unicode chars.
// NSTextView + NSRange approach eliminates this entirely — NSRange operates on
// UTF-16 code units, consistent with NSString, no conversion needed.
//
// WINDOW MIN-WIDTH FIX (CODE BLOCK):
// .fixedSize(horizontal: true, vertical: false) was applied to SyntaxHighlightedText
// inside ScrollView(.horizontal). fixedSize(horizontal: true) tells SwiftUI "give me
// as much width as I need" — this requirement propagates UP through the layout tree
// and prevents the window from being resized narrower than the longest code line.
// Fix: removed fixedSize entirely. ScrollView(.horizontal) already handles overflow
// correctly — content scrolls horizontally without forcing the window to expand.
//
// MULTI-LANGUAGE SYNTAX HIGHLIGHTING:
// SyntaxEngine supports 11 languages without any external dependencies.
// Architecture: shared engine (strings, numbers, comments) + per-language keyword sets.
// Languages: swift, python, javascript/js, typescript/ts, bash/sh/shell,
//            json, sql, kotlin, rust, go, c/cpp/c++/java (C-family).
// Unknown languages: plain text with theme color — always readable.

import SwiftUI
import AppKit

// MARK: - ASCII unichar constants
// Swift has no UInt16(ascii:) initializer. These constants replace all literal
// comparisons to avoid magic numbers and keep the code readable.
private let uniUnderscore:  unichar = 95   // _
private let uniAt:          unichar = 64   // @
private let uniHash:        unichar = 35   // #
private let uniDollar:      unichar = 36   // $
private let uniOpenBrace:   unichar = 123  // {
private let uniCloseBrace:  unichar = 125  // }
private let uniBackslash:   unichar = 92   // \
private let uniNewline:     unichar = 10   // \n
private let uniDoubleQuote: unichar = 34   // "
private let uniSingleQuote: unichar = 39   // '
private let uni0:           unichar = 48   // 0
private let uni9:           unichar = 57   // 9
private let uniA_upper:     unichar = 65   // A
private let uniZ_upper:     unichar = 90   // Z
private let uniA_lower:     unichar = 97   // a
private let uniZ_lower:     unichar = 122  // z
private let uniF_lower:     unichar = 102  // f
private let uniF_upper:     unichar = 70   // F
private let uniDot:         unichar = 46   // .
private let uniX_lower:     unichar = 120  // x
private let uniB_lower:     unichar = 98   // b

// MARK: - Syntax color themes (NSColor-based)

/// Color palette for syntax highlighting using NSColor.
///
/// WHY NSColor INSTEAD OF SwiftUI Color:
/// NSAttributedString used by NSTextView requires NSColor for .foregroundColor attribute.
/// SwiftUI Color in AttributedString is unreliable inside ScrollView on macOS —
/// the color gets silently dropped. NSColor + NSTextView = always correct rendering.
struct SyntaxNSTheme {

    let background: NSColor
    let plainText: NSColor
    let keyword: NSColor
    let type_: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor

    // MARK: Xcode Default Dark
    static let dark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1), // #1E1E1E
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1), // #F7F7F2
        keyword:    NSColor(red: 0.988, green: 0.373, blue: 0.639, alpha: 1), // #FC5FA3
        type_:      NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1), // #5DD8FF
        string:     NSColor(red: 0.988, green: 0.416, blue: 0.365, alpha: 1), // #FC6A5D
        number:     NSColor(red: 0.816, green: 0.749, blue: 0.412, alpha: 1), // #D0BF69
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1)  // #6C7986
    )

    // MARK: Xcode Default Light
    static let light = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1), // #FFFFFF
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1), // #000000
        keyword:    NSColor(red: 0.659, green: 0.055, blue: 0.565, alpha: 1), // #A80E90 — purple
        type_:      NSColor(red: 0.110, green: 0.384, blue: 0.655, alpha: 1), // #1C6278 — dark blue
        string:     NSColor(red: 0.773, green: 0.102, blue: 0.086, alpha: 1), // #C51A16 — dark red
        number:     NSColor(red: 0.118, green: 0.400, blue: 0.188, alpha: 1), // #1E6630 — dark green
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1)  // #686F75 — gray
    )
}

// MARK: - SwiftUI Color theme (for CodeBlockView chrome)

/// SwiftUI Color palette for CodeBlockView header/border/label — non-text UI elements.
///
/// SyntaxNSTheme covers the code text itself (NSTextView).
/// SyntaxTheme covers the surrounding chrome: header background, border, label color.
private struct SyntaxTheme {

    let background: Color
    let headerBackground: Color
    let border: Color
    let labelColor: Color

    static let dark = SyntaxTheme(
        background:       Color(red: 0.118, green: 0.118, blue: 0.118),
        headerBackground: Color(red: 0.145, green: 0.145, blue: 0.145),
        border:           Color(red: 0.250, green: 0.250, blue: 0.250),
        labelColor:       Color(red: 0.600, green: 0.600, blue: 0.600)
    )

    static let light = SyntaxTheme(
        background:       Color(red: 1.000, green: 1.000, blue: 1.000),
        headerBackground: Color(red: 0.953, green: 0.953, blue: 0.953),
        border:           Color(red: 0.851, green: 0.851, blue: 0.851),
        labelColor:       Color(red: 0.500, green: 0.500, blue: 0.500)
    )
}

// MARK: - Block model

/// Structural unit of parsed markdown text.
///
/// STABLE IDs: use positional index — prevents SwiftUI view identity collisions
/// when multiple blocks have similar content prefixes.
private enum MarkdownBlock: Identifiable {
    case paragraph(String, index: Int)
    case heading(String, level: Int, index: Int)
    case codeBlock(code: String, language: String?, index: Int)
    case divider(index: Int)
    case table(headers: [String], rows: [[String]], index: Int)

    var id: String {
        switch self {
        case .paragraph(_, let i):        return "p_\(i)"
        case .heading(_, _, let i):       return "h_\(i)"
        case .codeBlock(_, _, let i):     return "code_\(i)"
        case .divider(let i):             return "div_\(i)"
        case .table(_, _, let i):         return "table_\(i)"
        }
    }
}

// MARK: - Markdown parser

private struct MarkdownParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var blockIndex = 0

        while i < lines.count {
            let line = lines[i]

            // Code block: ```lang
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                blocks.append(.codeBlock(code: code, language: lang.isEmpty ? nil : lang, index: blockIndex))
                blockIndex += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Horizontal divider
            if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider(index: blockIndex)); blockIndex += 1; i += 1; continue
            }

            // Headings
            if line.hasPrefix("### ") {
                blocks.append(.heading(String(line.dropFirst(4)), level: 3, index: blockIndex))
                blockIndex += 1; i += 1; continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(String(line.dropFirst(3)), level: 2, index: blockIndex))
                blockIndex += 1; i += 1; continue
            }
            if line.hasPrefix("# ") {
                blocks.append(.heading(String(line.dropFirst(2)), level: 1, index: blockIndex))
                blockIndex += 1; i += 1; continue
            }

            // Table
            if trimmed.hasPrefix("|") {
                var tableLines: [String] = [line]
                i += 1
                while i < lines.count {
                    let nt = lines[i].trimmingCharacters(in: .whitespaces)
                    if nt.hasPrefix("|") { tableLines.append(lines[i]); i += 1 } else { break }
                }
                if let tb = parseTable(tableLines, index: blockIndex) {
                    blocks.append(tb); blockIndex += 1
                } else {
                    for tl in tableLines {
                        let tlt = tl.trimmingCharacters(in: .whitespaces)
                        if !tlt.isEmpty { blocks.append(.paragraph(tl, index: blockIndex)); blockIndex += 1 }
                    }
                }
                continue
            }

            // Empty line
            if trimmed.isEmpty { i += 1; continue }

            // Plain paragraph
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || next.hasPrefix("```")
                    || next.hasPrefix("# ") || next.hasPrefix("## ") || next.hasPrefix("### ")
                    || nextTrimmed == "---" || nextTrimmed.hasPrefix("|") { break }
                paragraphLines.append(next); i += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n"), index: blockIndex))
            blockIndex += 1
        }
        return blocks
    }

    private static func parseTable(_ lines: [String], index: Int) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }
        func parseCells(_ line: String) -> [String] {
            var cells = line.components(separatedBy: "|")
            if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
            if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let sep = lines[1].trimmingCharacters(in: .whitespaces)
        guard sep.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) else { return nil }
        let headers = parseCells(lines[0])
        guard !headers.isEmpty else { return nil }
        let rows = lines.dropFirst(2).map { parseCells($0) }
        return .table(headers: headers, rows: rows, index: index)
    }
}

// MARK: - Main component

struct MarkdownTextView: View {

    let text: String
    var textColor: Color = .primary
    var fontSize: CGFloat = 14

    // Parse once in init — stable, not recomputed on every render.
    private let blocks: [MarkdownBlock]

    init(text: String, textColor: Color = .primary, fontSize: CGFloat = 14) {
        self.text = text
        self.textColor = textColor
        self.fontSize = fontSize
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in blockView(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let rawText, _):
            InlineTextView(text: rawText, fontSize: fontSize, color: textColor)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        case .heading(let rawText, let level, _):
            headingView(text: rawText, level: level)
        case .codeBlock(let code, let language, _):
            CodeBlockView(code: code, language: language)
        case .divider:
            Divider().padding(.vertical, 4)
        case .table(let headers, let rows, _):
            TableBlockView(headers: headers, rows: rows, fontSize: fontSize)
        }
    }

    @ViewBuilder
    private func headingView(text: String, level: Int) -> some View {
        switch level {
        case 1:
            InlineTextView(text: text, fontSize: fontSize + 6, color: textColor, weight: .bold).padding(.top, 4)
        case 2:
            InlineTextView(text: text, fontSize: fontSize + 3, color: textColor, weight: .semibold).padding(.top, 2)
        default:
            InlineTextView(text: text, fontSize: fontSize + 1, color: textColor, weight: .medium)
        }
    }
}

// MARK: - Stable table row wrapper

private struct TableRow: Identifiable {
    let cells: [String]; let index: Int; let id: String
    init(cells: [String], index: Int) {
        self.cells = cells; self.index = index
        self.id = "\(index)_\(cells.joined().hashValue)"
    }
}

// MARK: - Table block

private struct TableBlockView: View {

    let headers: [String]; let rows: [[String]]; let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var borderColor: Color     { colorScheme == .dark ? Color(white: 0.3)   : Color(white: 0.75) }
    private var headerBackground: Color { colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.93) }
    private var rowBackground: Color    { colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.98) }
    private var altRowBackground: Color { colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.955) }

    private var tableRows: [TableRow] {
        rows.enumerated().map { TableRow(cells: $0.element, index: $0.offset) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tableRow(cells: headers, isHeader: true, background: headerBackground)
            Divider().background(borderColor)
            ForEach(tableRows) { row in
                tableRow(cells: row.cells, isHeader: false,
                         background: row.index % 2 == 0 ? rowBackground : altRowBackground)
                if row.index < rows.count - 1 { Divider().background(borderColor) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
    }

    @ViewBuilder
    private func tableRow(cells: [String], isHeader: Bool, background: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(paddedCells(cells).enumerated()), id: \.offset) { _, cell in
                InlineTextView(text: cell, fontSize: fontSize - 1, color: .primary,
                               weight: isHeader ? .semibold : .regular)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(background)
    }

    private func paddedCells(_ cells: [String]) -> [String] {
        let count = headers.count
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }
}

// MARK: - Inline text

/// Renders a string with inline markup (**bold**, *italic*, `code`).
///
/// Color is passed via .foregroundStyle() — NOT via AttributedString.foregroundColor,
/// which is unreliable inside ScrollView on macOS.
private struct InlineTextView: View {

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

// MARK: - Code block

/// Renders a code block in Xcode Intelligence Panel style.
///
/// Uses SyntaxHighlightedText (NSViewRepresentable) for the code body —
/// guarantees correct color rendering via NSTextView + NSAttributedString.
struct CodeBlockView: View {

    let code: String
    let language: String?

    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SyntaxTheme     { colorScheme == .dark ? .dark : .light }
    private var nsTheme: SyntaxNSTheme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header: language label + copy button
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.labelColor).padding(.leading, 12)
                Spacer()
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        Text(copied ? "Скопировано" : "Копировать").font(.system(size: 11))
                    }
                    .foregroundStyle(copied ? Color(red: 0.3, green: 0.75, blue: 0.3) : theme.labelColor)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain).animation(.easeInOut(duration: 0.2), value: copied)
            }
            .padding(.vertical, 4).background(theme.headerBackground)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }

            // Code body — NSTextView for reliable color rendering.
            // NO fixedSize(horizontal: true) — ScrollView handles overflow.
            ScrollView(.horizontal, showsIndicators: false) {
                SyntaxHighlightedText(code: code, language: language, theme: nsTheme).padding(12)
            }
            .background(theme.background)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
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

// MARK: - NSViewRepresentable syntax highlighted text view

/// NSTextView-based syntax highlighted code view.
///
/// WHY NSViewRepresentable:
/// SwiftUI Text(AttributedString) silently drops foregroundColor attributes
/// when nested inside ScrollView on macOS. NSTextView renders NSAttributedString
/// with NSColor directly — always correct, no SwiftUI attribute scope confusion.
private struct SyntaxHighlightedText: NSViewRepresentable {

    let code: String
    let language: String?
    let theme: SyntaxNSTheme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Allow horizontal expansion — parent SwiftUI ScrollView handles overflow.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let highlighted = SyntaxEngine.highlight(code: code, language: language, theme: theme)
        textView.textStorage?.setAttributedString(highlighted)
        // Resize to fit content so SwiftUI can measure the view correctly.
        textView.sizeToFit()
        scrollView.frame.size = textView.frame.size
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let rect = lm.usedRect(for: tc)
        return CGSize(width: rect.width, height: rect.height)
    }
}

// MARK: - Syntax engine (NSAttributedString-based)

/// Produces NSAttributedString with syntax coloring for 11 languages.
///
/// All coloring uses NSColor via NSRange — reliable in NSTextView,
/// no SwiftUI attribute scope issues, no unicode index mismatches.
private enum SyntaxEngine {

    static func highlight(code: String, language: String?, theme: SyntaxNSTheme) -> NSAttributedString {
        let lang = normalize(language)
        switch lang {
        case "swift":
            return kw(code, keywords: swiftKeywords, types: true, comment: .slashSlash, theme: theme)
        case "python":
            return kw(code, keywords: pythonKeywords, types: false, comment: .hash, theme: theme)
        case "javascript":
            return kw(code, keywords: jsKeywords, types: false, comment: .slashSlash, theme: theme)
        case "typescript":
            return kw(code, keywords: tsKeywords, types: false, comment: .slashSlash, theme: theme)
        case "kotlin":
            return kw(code, keywords: kotlinKeywords, types: true, comment: .slashSlash, theme: theme)
        case "rust":
            return kw(code, keywords: rustKeywords, types: true, comment: .slashSlash, theme: theme)
        case "go":
            return kw(code, keywords: goKeywords, types: true, comment: .slashSlash, theme: theme)
        case "java":
            return kw(code, keywords: javaKeywords, types: true, comment: .slashSlash, theme: theme)
        case "c", "cpp":
            return kw(code, keywords: cKeywords, types: false, comment: .slashSlash, theme: theme)
        case "bash":
            return bash(code, theme: theme)
        case "json":
            return json(code, theme: theme)
        case "sql":
            return kw(code, keywords: sqlKeywords, types: false, comment: .doubleDash,
                      theme: theme, caseInsensitive: true)
        default:
            return plain(code, theme: theme)
        }
    }

    // MARK: - Language normalization

    private static func normalize(_ language: String?) -> String {
        switch language?.lowercased() ?? "" {
        case "js", "javascript":    return "javascript"
        case "ts", "typescript":    return "typescript"
        case "sh", "shell", "bash": return "bash"
        case "cpp", "c++":          return "cpp"
        case "swift":               return "swift"
        case "python", "py":        return "python"
        case "kotlin", "kt":        return "kotlin"
        case "rust", "rs":          return "rust"
        case "go", "golang":        return "go"
        case "java":                return "java"
        case "json":                return "json"
        case "sql":                 return "sql"
        case "c":                   return "c"
        default:                    return language?.lowercased() ?? ""
        }
    }

    // MARK: - Comment styles

    private enum CommentStyle { case slashSlash, hash, doubleDash }

    // MARK: - Plain text fallback

    private static func plain(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code)
        let r = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: r)
        result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: r)
        return result
    }

    // MARK: - Generic keyword highlighter

    private static func kw(
        _ code: String,
        keywords: [String],
        types: Bool,
        comment: CommentStyle,
        theme: SyntaxNSTheme,
        caseInsensitive: Bool = false
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: full)
        result.addAttribute(.font, value: font, range: full)
        for kw in keywords { colorWord(theme.keyword, word: kw, in: result, ci: caseInsensitive) }
        if types { colorTypes(theme.type_, in: result) }
        colorStrings(theme.string, in: result)
        colorNumbers(theme.number, in: result)
        switch comment {
        case .slashSlash: colorComments("//", color: theme.comment, in: result)
        case .hash:       colorComments("#",  color: theme.comment, in: result)
        case .doubleDash: colorComments("--", color: theme.comment, in: result)
        }
        return result
    }

    // MARK: - Bash

    private static func bash(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: full)
        result.addAttribute(.font, value: font, range: full)
        for kw in bashKeywords { colorWord(theme.keyword, word: kw, in: result) }
        colorBashVars(theme.type_, in: result)
        colorStrings(theme.string, in: result)
        colorNumbers(theme.number, in: result)
        colorComments("#", color: theme.comment, in: result)
        return result
    }

    // MARK: - JSON

    private static func json(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: full)
        result.addAttribute(.font, value: font, range: full)
        for kw in ["true", "false", "null"] { colorWord(theme.keyword, word: kw, in: result) }
        colorStrings(theme.string, in: result)
        colorNumbers(theme.number, in: result)
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
        "delete", "void", "yield"
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

    // MARK: - Coloring primitives (NSRange + unichar — no unicode index issues)

    /// Returns true if a UTF-16 code unit is a word character (letter, digit, _, @, #).
    private static func isWord(_ c: unichar) -> Bool {
        if c == uniUnderscore || c == uniAt || c == uniHash { return true }
        if c >= uni0 && c <= uni9 { return true }
        if c >= uniA_upper && c <= uniZ_upper { return true }
        if c >= uniA_lower && c <= uniZ_lower { return true }
        if c > 127 { return true } // Unicode letters (Cyrillic etc.)
        return false
    }

    /// Applies NSColor to all word-boundary occurrences of a keyword.
    private static func colorWord(
        _ color: NSColor, word: String, in str: NSMutableAttributedString, ci: Bool = false
    ) {
        let text = str.string
        let options: NSString.CompareOptions = ci ? [.literal, .caseInsensitive] : [.literal]
        var searchRange = NSRange(location: 0, length: text.utf16.count)

        while searchRange.length > 0 {
            let found = (text as NSString).range(of: word, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            let ns = text as NSString
            let leftOk  = found.location == 0 || !isWord(ns.character(at: found.location - 1))
            let endLoc  = found.location + found.length
            let rightOk = endLoc >= ns.length || !isWord(ns.character(at: endLoc))
            if leftOk && rightOk { str.addAttribute(.foregroundColor, value: color, range: found) }
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: text.utf16.count - next)
        }
    }

    /// Highlights PascalCase words as type names.
    private static func colorTypes(_ color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            guard c >= uniA_upper && c <= uniZ_upper else { i += 1; continue }
            var j = i + 1
            while j < ns.length && isWord(ns.character(at: j)) { j += 1 }
            if j - i > 1 { str.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: j - i)) }
            i = j
        }
    }

    /// Highlights string literals in double and single quotes.
    private static func colorStrings(_ color: NSColor, in str: NSMutableAttributedString) {
        for q: unichar in [uniDoubleQuote, uniSingleQuote] {
            let ns = str.string as NSString
            var i = 0; var inStr = false; var start = 0
            while i < ns.length {
                let c = ns.character(at: i)
                if c == q && !inStr         { inStr = true; start = i }
                else if c == q && inStr     { inStr = false; str.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: i - start + 1)) }
                else if c == uniBackslash && inStr { i += 1; if i >= ns.length { break } }
                else if c == uniNewline && inStr   { inStr = false }
                i += 1
            }
        }
    }

    /// Highlights numeric literals.
    private static func colorNumbers(_ color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            guard c >= uni0 && c <= uni9 else { i += 1; continue }
            if i > 0 && isWord(ns.character(at: i - 1)) { i += 1; continue }
            var j = i
            while j < ns.length {
                let ch = ns.character(at: j)
                let ok = (ch >= uni0 && ch <= uni9)
                    || ch == uniDot || ch == uniUnderscore
                    || ch == uniX_lower || ch == uniB_lower
                    || (ch >= uniA_lower && ch <= uniF_lower)
                    || (ch >= uniA_upper && ch <= uniF_upper)
                if !ok { break }
                j += 1
            }
            str.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: j - i))
            i = j
        }
    }

    /// Highlights single-line comments from prefix to end of line.
    private static func colorComments(_ prefix: String, color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        let pLen = prefix.utf16.count
        var i = 0
        while i < ns.length {
            if i + pLen <= ns.length,
               ns.substring(with: NSRange(location: i, length: pLen)) == prefix {
                var j = i
                while j < ns.length && ns.character(at: j) != uniNewline { j += 1 }
                str.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: j - i))
                i = j + 1
            } else {
                i += 1
            }
        }
    }

    /// Highlights $VAR and ${VAR} bash variable references.
    private static func colorBashVars(_ color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            guard ns.character(at: i) == uniDollar else { i += 1; continue }
            let start = i; i += 1
            guard i < ns.length else { break }
            if ns.character(at: i) == uniOpenBrace {
                i += 1
                while i < ns.length && ns.character(at: i) != uniCloseBrace { i += 1 }
                if i < ns.length { i += 1; str.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: i - start)) }
            } else {
                while i < ns.length && isWord(ns.character(at: i)) { i += 1 }
                if i > start + 1 { str.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: i - start)) }
            }
        }
    }
}

// MARK: - Preview

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

#Preview("Multi-language highlighting — Light") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            CodeBlockView(code: """
            import Foundation

            struct User {
                let id: UUID
                var name: String
                var isValid: Bool { !name.isEmpty }
            }

            func greet(_ user: User) -> String {
                return "Hello, \\(user.name)!"
            }
            """, language: "swift")

            CodeBlockView(code: """
            {
                "user": {
                    "id": 42,
                    "name": "Sergey",
                    "active": true,
                    "score": 3.14,
                    "address": null
                }
            }
            """, language: "json")

            CodeBlockView(code: """
            -- Users table
            CREATE TABLE users (
                id   SERIAL PRIMARY KEY,
                name VARCHAR(255) NOT NULL,
                role VARCHAR(50)  DEFAULT 'user'
            );

            SELECT id, name FROM users WHERE role = 'admin';
            """, language: "sql")
        }
        .padding()
    }
    .frame(width: 650, height: 700)
    .background(Color(NSColor.windowBackgroundColor))
    .preferredColorScheme(.light)
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
