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
