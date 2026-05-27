// InputMorphView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Replaces the old InputBarView + StatusBarView pair with a single morphing component.
// The idea: the input bar IS the status bar — it transforms in place.
//
// IDLE state:    [ TextEditor (1–10 lines, scrollable) ] [▶ Send]
// THINKING state: [ ⚙ write_file → ContentView…       ] [✕ Cancel]
//
// DESIGN DECISIONS:
// - TextEditor instead of TextField: gives us real scroll when content > 10 lines.
// - Dynamic height: measured via GeometryReader, capped at maxIdleHeight.
// - On send: height animates DOWN to collapsedHeight (single line) before morphing.
// - On finish/cancel: height animates back to whatever the editor needs.
// - Cancel button calls viewModel.cancelCurrentRequest() — real Task cancellation.
// - After cancel/error/completion — morphs back to idle, TextEditor auto-focuses.
// - Newline: both ⌥+Enter AND ⇧+Enter insert a newline (muscle memory from messengers).
// - Send: plain Enter only.

import SwiftUI

// MARK: - Constants

private enum Layout {
    /// Single-line height of the thinking bar (gear + label + cancel).
    static let collapsedHeight: CGFloat = 28
    /// Line height approximation for the TextEditor (font size + padding).
    static let lineHeight: CGFloat = 20
    /// Vertical padding inside the TextEditor frame.
    static let editorVerticalPadding: CGFloat = 6
    /// Maximum number of visible lines before scroll kicks in.
    static let maxLines: Int = 10
    /// Maximum height of the TextEditor frame.
    static var maxEditorHeight: CGFloat {
        CGFloat(maxLines) * lineHeight + editorVerticalPadding * 2
    }
    /// Minimum height of the TextEditor frame (one line).
    static var minEditorHeight: CGFloat {
        lineHeight + editorVerticalPadding * 2
    }
}

// MARK: - InputMorphView

struct InputMorphView: View {

    // MARK: - Inputs

    /// Current text in the input field. Owned by ContentView, cleared on send.
    @Binding var prompt: String

    /// True when workspace folder is selected (required to send).
    let isWorkspaceSelected: Bool

    /// True while Chappie is processing a request (thinking / calling tools).
    let isThinking: Bool

    /// Current tool call string, e.g. "write_file → ContentView.swift".
    /// nil = no tool call running.
    let currentToolCall: String?

    /// Called when the user taps Send or presses Enter (without modifiers).
    let onSend: () -> Void

    /// Called when the user taps Cancel during thinking.
    let onCancel: () -> Void

    // MARK: - Private State

    /// Tracks focus on the text editor so we can restore it after cancel/error.
    @FocusState private var isEditorFocused: Bool

    /// Computed height of the TextEditor based on current text line count.
    /// Capped between minEditorHeight and maxEditorHeight.
    @State private var editorHeight: CGFloat = Layout.minEditorHeight

    // MARK: - Computed

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isWorkspaceSelected
        && !isThinking
    }

    /// Height used for the inner content area.
    /// - Thinking: collapsed to single line.
    /// - Idle: dynamic based on text content.
    private var contentHeight: CGFloat {
        isThinking ? Layout.collapsedHeight : editorHeight
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Idle state: text editor + send button
            idleView
                .opacity(isThinking ? 0 : 1)
                .scaleEffect(isThinking ? 0.96 : 1, anchor: .bottom)

            // Thinking state: tool call label + cancel button
            thinkingView
                .opacity(isThinking ? 1 : 0)
                .scaleEffect(isThinking ? 1 : 0.96, anchor: .bottom)
        }
        // Height morphs smoothly between collapsed and expanded
        .frame(height: contentHeight)
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 16)
        // Single smooth spring animation drives both opacity/scale AND height
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isThinking)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: editorHeight)
        // Restore focus when Chappie finishes thinking
        .onChange(of: isThinking) { _, nowThinking in
            if !nowThinking {
                // Small delay so SwiftUI finishes the transition before focusing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    isEditorFocused = true
                }
            }
        }
        // Recalculate editor height whenever prompt text changes
        .onChange(of: prompt) { _, newValue in
            updateEditorHeight(for: newValue)
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // TextEditor gives real scroll when content exceeds maxLines.
            // We fix its frame height and let it scroll internally.
            ScrollView(.vertical, showsIndicators: true) {
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .focused($isEditorFocused)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    // Key handling strategy:
                    // - Plain Enter → send message
                    // - ⇧+Enter or ⌥+Enter → insert newline (both are valid muscle memory)
                    .onKeyPress(.return) {
                        let mods = NSEvent.modifierFlags
                        let isNewlineCombo = mods.contains(.shift) || mods.contains(.option)
                        if isNewlineCombo {
                            // Insert newline at current cursor position
                            insertNewline()
                            return .handled
                        }
                        // Plain Enter — send message
                        if canSend { onSend() }
                        return .handled
                    }
                    .disabled(!isWorkspaceSelected || isThinking)
                    // Inner frame matches the outer animated height exactly
                    .frame(height: editorHeight)
            }
            // Outer frame clips scroll view to our animated height
            .frame(height: editorHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isEditorFocused
                        ? Color.accentColor.opacity(0.6)
                        : Color(NSColor.separatorColor),
                        lineWidth: 1)
            )
            // Placeholder text when prompt is empty
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Напиши сообщение… (Enter — отправить, ⇧+Enter — перенос)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(NSColor.placeholderTextColor))
                        .padding(.horizontal, 5)
                        .padding(.vertical, Layout.editorVerticalPadding)
                        .allowsHitTesting(false)
                }
            }

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            // Align button to the bottom edge of the (possibly multiline) editor
            .padding(.bottom, 2)
        }
    }

    // MARK: - Thinking View

    private var thinkingView: some View {
        HStack(spacing: 12) {
            // Spinning gear icon — signals active processing
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, options: .repeating)

            // Tool call label — updates in place as tools are called
            Text(currentToolCall ?? "Думаю…")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                // Animate text changes smoothly
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: currentToolCall)

            Spacer()

            // Cancel button — real Task cancellation, not just UI
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

    // MARK: - Height Calculation

    /// Recalculates editorHeight based on the number of lines in the text.
    /// Uses approximate line height — good enough for smooth animation.
    private func updateEditorHeight(for text: String) {
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        let clamped = min(lineCount, Layout.maxLines)
        let newHeight = CGFloat(clamped) * Layout.lineHeight + Layout.editorVerticalPadding * 2
        if abs(newHeight - editorHeight) > 1 {
            editorHeight = newHeight
        }
    }

    // MARK: - Newline Insertion

    /// Inserts a newline character at the current cursor position.
    /// We manipulate the binding directly — SwiftUI handles cursor placement.
    private func insertNewline() {
        // NSTextView (underlying AppKit control) handles cursor position.
        // Appending to the binding is not ideal, but SwiftUI TextEditor
        // does not expose cursor position. The standard workaround is to
        // post a fake event, but that is fragile. Instead we rely on
        // returning .ignored so AppKit inserts the newline natively —
        // but we need .handled to prevent the send. So we use NSApp to
        // forward a plain Return event without modifiers via the responder chain.
        if let window = NSApp.keyWindow,
           let event = NSEvent.keyEvent(
               with: .keyDown,
               location: .zero,
               modifierFlags: [],
               timestamp: 0,
               windowNumber: window.windowNumber,
               context: nil,
               characters: "\n",
               charactersIgnoringModifiers: "\n",
               isARepeat: false,
               keyCode: 36
           ) {
            window.firstResponder?.keyDown(with: event)
        }
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

#Preview("Thinking — no tool yet") {
    VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            isWorkspaceSelected: true,
            isThinking: true,
            currentToolCall: nil,
            onSend: {},
            onCancel: {}
        )
    }
    .frame(width: 600, height: 120)
}
