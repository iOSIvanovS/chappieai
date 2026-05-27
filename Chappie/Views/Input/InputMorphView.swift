// InputMorphView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Replaces the old InputBarView + StatusBarView pair with a single morphing component.
// The idea: the input bar IS the status bar — it transforms in place.
//
// IDLE state:    [ ChappieTextEditorView (1–10 lines, scrollable) ] [▶ Send]
// THINKING state: [ ⚙ write_file → ContentView…                  ] [✕ Cancel]
//
// DESIGN DECISIONS:
// - ChappieTextView (NSTextView subclass): overrides keyDown for reliable key interception.
//   SwiftUI's onKeyPress on TextEditor is unreliable — AppKit consumes events first.
//   Subclassing is the ONLY guaranteed approach on macOS.
// - Plain Enter → send. Shift+Enter or Option+Enter → insert newline.
// - Dynamic height: measured via NSLayoutManager (handles word-wrap correctly),
//   capped at maxLines, with spring animation.
// - On send: editorHeight resets to minEditorHeight immediately; morph animates to collapsedHeight.
// - On finish/cancel: height restores from editorHeight; editor auto-focuses via coordinator.
//
// SCROLL INTEGRATION:
// - onHeightChange callback fires whenever the panel's rendered height changes.
// - ContentView uses this to set bottomPadding on ChatScrollView, so the last message
//   is never hidden under the panel — on launch, on grow, or on collapse.

import SwiftUI
import AppKit

// MARK: - Layout Constants

private enum Layout {
    static let collapsedHeight: CGFloat = 28
    static let lineHeight: CGFloat = 20
    static let editorVerticalPadding: CGFloat = 6
    static let maxLines: Int = 10

    // Outer padding around the panel (horizontal + bottom)
    static let outerHorizontalPadding: CGFloat = 16 // .padding(.horizontal)
    static let outerBottomPadding: CGFloat = 16      // .padding(.bottom, 16)
    static let innerPadding: CGFloat = 12            // .padding(12) inside the panel

    static var maxEditorHeight: CGFloat {
        CGFloat(maxLines) * lineHeight + editorVerticalPadding * 2
    }
    static var minEditorHeight: CGFloat {
        lineHeight + editorVerticalPadding * 2
    }
}

// MARK: - ChappieTextView

/// NSTextView subclass with direct keyDown interception.
/// This is the ONLY reliable way to distinguish plain Enter from Shift+Enter on macOS —
/// AppKit processes key events before SwiftUI's onKeyPress can see them.
final class ChappieTextView: NSTextView {

    /// Fired when the user presses plain Enter (no modifiers). Triggers message send.
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return / Enter
        guard event.keyCode == 36 else {
            super.keyDown(with: event)
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.shift) || mods.contains(.option) {
            // Shift+Enter or Option+Enter → insert real newline at cursor position
            insertNewline(nil)
        } else {
            // Plain Enter → trigger send
            onSend?()
        }
    }
}

// MARK: - ChappieTextEditorView

/// NSViewRepresentable wrapping ChappieTextView inside an NSScrollView.
/// Exposes text binding, height change callback, focus change callback,
/// and surfaces Coordinator for imperative focus control.
struct ChappieTextEditorView: NSViewRepresentable {

    @Binding var text: String
    var isEnabled: Bool
    var onSend: () -> Void
    var onHeightChange: (CGFloat) -> Void
    var onFocusChange: ((Bool) -> Void)?
    var onCoordinatorReady: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let textView = ChappieTextView()
        textView.onSend = { [weak coordinator] in
            coordinator?.parent.onSend()
        }
        textView.delegate = coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 4, height: Layout.editorVerticalPadding)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        coordinator.textView = textView

        DispatchQueue.main.async {
            coordinator.parent.onCoordinatorReady?(coordinator)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChappieTextView else { return }

        let coordinator = context.coordinator
        textView.onSend = { [weak coordinator] in
            coordinator?.parent.onSend()
        }

        // Sync text only when changed externally (e.g. cleared after send)
        if textView.string != text {
            textView.string = text
            // Recalculate height after layout pass so layoutManager has fresh data
            DispatchQueue.main.async {
                coordinator.recalculateHeight(textView)
            }
        }

        textView.isEditable = isEnabled
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChappieTextEditorView
        weak var textView: ChappieTextView?

        init(parent: ChappieTextEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalculateHeight(tv)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange?(false)
        }

        /// Measures real rendered height using NSLayoutManager.
        /// This correctly handles word-wrap — unlike counting "\n" characters.
        func recalculateHeight(_ textView: NSTextView) {
            guard
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            // Force layout to be up to date before measuring
            layoutManager.ensureLayout(for: textContainer)

            let usedRect = layoutManager.usedRect(for: textContainer)
            // usedRect.height reflects actual rendered lines including word-wrap
            let contentHeight = usedRect.height + Layout.editorVerticalPadding * 2
            let clamped = min(contentHeight, Layout.maxEditorHeight)
            let final = max(clamped, Layout.minEditorHeight)

            parent.onHeightChange(final)
        }

        /// Makes the underlying NSTextView first responder.
        func focus() {
            textView?.window?.makeFirstResponder(textView)
        }
    }
}

// MARK: - InputMorphView

struct InputMorphView: View {

    // MARK: - Inputs

    @Binding var prompt: String
    let isWorkspaceSelected: Bool
    let isThinking: Bool
    let currentToolCall: String?
    let onSend: () -> Void
    let onCancel: () -> Void

    /// Called whenever the panel's total rendered height changes.
    /// ContentView uses this to update ChatScrollView's bottom padding.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    // MARK: - Private State

    @State private var isEditorFocused: Bool = false
    @State private var editorHeight: CGFloat = Layout.minEditorHeight
    @State private var editorCoordinator: ChappieTextEditorView.Coordinator?

    // MARK: - Computed

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isWorkspaceSelected
        && !isThinking
    }

    private var contentHeight: CGFloat {
        // While thinking: always collapsed. Otherwise: use real editor height.
        isThinking ? Layout.collapsedHeight : editorHeight
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            idleView
                .opacity(isThinking ? 0 : 1)
                .scaleEffect(isThinking ? 0.96 : 1, anchor: .bottom)

            thinkingView
                .opacity(isThinking ? 1 : 0)
                .scaleEffect(isThinking ? 1 : 0.96, anchor: .bottom)
        }
        .frame(height: contentHeight)
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isThinking)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: editorHeight)
        // Report total rendered height via GeometryReader so ChatScrollView can pad correctly.
        // background(GeometryReader) is a standard SwiftUI pattern — doesn't affect layout.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        onHeightChange?(geo.size.height)
                    }
                    .onChange(of: geo.size.height) { _, newHeight in
                        onHeightChange?(newHeight)
                    }
            }
        )
        .onChange(of: isThinking) { _, nowThinking in
            if !nowThinking {
                // Small delay lets the morph animation finish before focusing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    editorCoordinator?.focus()
                }
            }
        }
        .onChange(of: prompt) { _, newValue in
            // When prompt is cleared externally (after send) — reset editor height immediately.
            // This ensures the panel doesn't stay tall when morphing back from thinking state.
            if newValue.isEmpty {
                editorHeight = Layout.minEditorHeight
            }
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ChappieTextEditorView(
                text: $prompt,
                isEnabled: isWorkspaceSelected && !isThinking,
                onSend: { if canSend { onSend() } },
                onHeightChange: { newHeight in
                    // Only update while not thinking — avoids fighting the collapse animation
                    if !isThinking, abs(newHeight - editorHeight) > 1 {
                        editorHeight = newHeight
                    }
                },
                onFocusChange: { focused in
                    isEditorFocused = focused
                },
                onCoordinatorReady: { coordinator in
                    editorCoordinator = coordinator
                }
            )
            .frame(height: editorHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isEditorFocused
                            ? Color.accentColor.opacity(0.6)
                            : Color(NSColor.separatorColor),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Напиши сообщение… (⇧+Enter — перенос строки)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(NSColor.placeholderTextColor))
                        .padding(.horizontal, 9)
                        .padding(.vertical, Layout.editorVerticalPadding)
                        .allowsHitTesting(false)
                }
            }

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            .padding(.bottom, 2)
        }
    }

    // MARK: - Thinking View

    private var thinkingView: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, options: .repeating)

            Text(currentToolCall ?? "Думаю…")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: currentToolCall)

            Spacer()

            Button(action: onCancel) {
                Label("Отмена", systemImage: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Прервать текущий запрос")
        }
        .frame(height: Layout.collapsedHeight)
    }
}

// MARK: - Preview

#Preview("Idle — empty") {
    VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            isWorkspaceSelected: true,
            isThinking: false,
            currentToolCall: nil,
            onSend: {},
            onCancel: {}
        )
    }
    .frame(width: 600, height: 160)
}

#Preview("Idle — multiline") {
    VStack {
        Spacer()
        InputMorphView(
            prompt: .constant("Строка 1\nСтрока 2\nСтрока 3\nСтрока 4\nСтрока 5"),
            isWorkspaceSelected: true,
            isThinking: false,
            currentToolCall: nil,
            onSend: {},
            onCancel: {}
        )
    }
    .frame(width: 600, height: 260)
}

#Preview("Thinking — tool call") {
    VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            isWorkspaceSelected: true,
            isThinking: true,
            currentToolCall: "write_file → Chappie/Views/Input/InputMorphView.swift",
            onSend: {},
            onCancel: {}
        )
    }
    .frame(width: 600, height: 120)
}
