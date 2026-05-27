// InputMorphView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Replaces the old InputBarView + StatusBarView pair with a single morphing component.
// The idea: the input bar IS the status bar — it transforms in place.
//
// IDLE state:    [ TextField                     ] [▶ Send]
// THINKING state: [ ⚙ write_file → ContentView… ] [✕ Cancel]
//
// DESIGN DECISIONS:
// - Single fixed-height container — no layout jumps during transition.
// - crossfade (.opacity transition) between inner views — smooth, non-distracting.
// - Cancel button calls viewModel.cancelCurrentRequest() — real Task cancellation.
// - After cancel/error/completion — morphs back to idle, TextField auto-focuses.
// - The component owns no state besides @FocusState — all state lives in ViewModel.

import SwiftUI

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

    /// Called when the user taps Send or presses Enter.
    let onSend: () -> Void

    /// Called when the user taps Cancel during thinking.
    let onCancel: () -> Void

    // MARK: - Private State

    /// Tracks focus on the text field so we can restore it after cancel/error.
    @FocusState private var isTextFieldFocused: Bool

    // MARK: - Computed

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isWorkspaceSelected
        && !isThinking
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Idle state: text field + send button
            idleView
                .opacity(isThinking ? 0 : 1)
                .scaleEffect(isThinking ? 0.96 : 1, anchor: .bottom)

            // Thinking state: tool call label + cancel button
            thinkingView
                .opacity(isThinking ? 1 : 0)
                .scaleEffect(isThinking ? 1 : 0.96, anchor: .bottom)
        }
        // Shared container — same padding and background in both states
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 16)
        // Single smooth animation driven by isThinking toggle
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isThinking)
        // Restore focus when Chappie finishes thinking
        .onChange(of: isThinking) { _, nowThinking in
            if !nowThinking {
                // Small delay so SwiftUI finishes the transition before focusing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    isTextFieldFocused = true
                }
            }
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField(
                "Напиши сообщение... (Enter — отправить, ⌥+Enter — перенос)",
                text: $prompt,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...10)
            .focused($isTextFieldFocused)
            .onSubmit { onSend() }
            .disabled(!isWorkspaceSelected || isThinking)

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            // Align button to the bottom edge of the (possibly multiline) text field
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
        // Match the height of the idle text field (single-line baseline)
        .frame(minHeight: 28)
    }
}

// MARK: - Preview

#Preview("Idle") {
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
    .frame(width: 600, height: 120)
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
