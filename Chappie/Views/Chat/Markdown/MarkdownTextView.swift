// MarkdownTextView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Chappie responses heavily use markdown: code blocks (Swift/bash),
// inline code, bold text, headings. Standard SwiftUI Text doesn't support
// code blocks with syntax highlighting. This component fills that gap.
//
// PARSER ARCHITECTURE:
// Simple linear line-by-line parser — not RegEx, not AST.
// Reason: Chappie Swift responses have predictable structure.
// A full markdown parser (CommonMark) would be overkill and add a dependency.
//
// WHY NSViewRepresentable FOR SYNTAX HIGHLIGHTING:
// SwiftUI Text(AttributedString) with .foregroundColor set on AttributedString
// segments is unreliable on macOS — the color is silently ignored when the
// Text is nested inside ScrollView or certain container views.
// NSTextView renders NSAttributedString with NSColor directly — always correct.

import SwiftUI
import AppKit

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
//        .frame(maxWidth: .infinity, alignment: .leading)
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
            // CPU-04: EquatableView skips re-render when headers/rows/fontSize unchanged.
            // Tables are the heaviest block — this guard is the most impactful.
            EquatableView(content: TableBlockView(headers: headers, rows: rows, fontSize: fontSize))
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

struct TableRow: Identifiable {
    let cells: [String]; let index: Int; let id: String
    init(cells: [String], index: Int) {
        self.cells = cells; self.index = index
        self.id = "\(index)_\(cells.joined().hashValue)"
    }
}

// MARK: - Table block

/// CPU-04: Equatable conformance lets EquatableView skip re-render when inputs are unchanged.
/// Tables are the most expensive block to layout — this guard pays off most here.
struct TableBlockView: View, Equatable {

    let headers: [String]; let rows: [[String]]; let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: TableBlockView, rhs: TableBlockView) -> Bool {
        lhs.headers == rhs.headers && lhs.rows == rhs.rows && lhs.fontSize == rhs.fontSize
    }

    private var borderColor: Color      { colorScheme == .dark ? Color(white: 0.3)   : Color(white: 0.75) }
    private var headerBackground: Color { colorScheme == .dark ? Color(white: 0.18)  : Color(white: 0.93) }
    private var rowBackground: Color    { colorScheme == .dark ? Color(white: 0.13)  : Color(white: 0.98) }
    private var altRowBackground: Color { colorScheme == .dark ? Color(white: 0.16)  : Color(white: 0.955) }

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

// MARK: - Previews

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
