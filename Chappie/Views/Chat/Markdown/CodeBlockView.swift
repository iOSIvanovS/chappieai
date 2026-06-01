// CodeBlockView.swift
// Chappie

import SwiftUI
import AppKit

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
    // Per-language theme — each language gets its own color identity.
    private var nsTheme: SyntaxNSTheme {
        let lang = SyntaxEngine.normalizePublic(language)
        return SyntaxNSTheme.forLanguage(lang, dark: colorScheme == .dark)
    }

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
