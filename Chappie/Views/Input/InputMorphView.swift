// InputMorphView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Replaces the old InputBarView + StatusBarView pair with a single morphing component.
// The idea: the input bar IS the status bar — it transforms in place.
//
// IDLE state:    [ ChappieTextEditorView (1–10 lines, scrollable) ] [📎] [😊] [▶ Send]
// THINKING state: [ ⚙ write_file → ContentView…                  ] [✕ Cancel]
//
// DESIGN DECISIONS:
// - ChappieTextView (NSTextView subclass): overrides keyDown for reliable key interception.
//   SwiftUI's onKeyPress on TextEditor is unreliable — AppKit consumes events first.
//   Subclassing is the ONLY guaranteed approach on macOS.
// - Plain Enter → send. Shift+Enter or Option+Enter → insert newline.
// - Dynamic height: measured via NSLayoutManager (handles word-wrap correctly),
//   capped at maxLines, with linear animation (not spring — avoids 60fps timer loop).
// - On send: editorHeight resets to minEditorHeight immediately; morph animates to collapsedHeight.
// - On finish/cancel: height restores from editorHeight; editor auto-focuses via coordinator.
//
// HEIGHT STRATEGY (CPU-16 — STATIC FOOTER):
// - InputMorphView no longer reports its height to ContentView.
// - ChatScrollView uses InputLayout.maxPanelHeight as a fixed footer spacer.
// - Previously: editorHeight changed on every keystroke → onHeightChange callback →
//   bottomPanelHeight state in ContentView → footerHeight prop in ChatScrollView →
//   layout pass on every character. This was the main source of 75% CPU while typing.
// - Now: the footer is always the size of the tallest possible panel. The user never
//   sees content hidden behind the bar. Zero layout passes from typing.
//
// CPU-10: THREE ANIMATIONS → ONE TOKEN (morph-only):
// - Previously three separate .animation(..., value:) modifiers were stacked on the root view.
// - Fix (CPU-14): animationToken combines ONLY isThinking + attachments.isEmpty.
//   editorHeight is animated separately via its own .animation modifier scoped to the editor frame.
//   Morph (thinking↔idle) still gets the full spring. Typing no longer triggers root animation.
//
// CPU-13: STREAMING ISOLATION:
// - InputMorphView receives `streaming: StreamingState` instead of separate isThinking
//   and currentToolCall parameters. It reads streaming.isThinking and streaming.currentToolCall
//   directly — subscribing to StreamingState, NOT to ViewModel.
//
// MULTIMODAL:
// - Paperclip button opens NSOpenPanel (images, PDF, text, any file).
// - attachments: [AttachedFile] is a @Binding from ContentView — NOT local @State.
// - AttachmentChipsRow renders above the text editor when attachments are non-empty.
// - onSend now receives ([AttachedFile]) → caller is responsible for consuming them.
//
// DRAG & DROP:
// - Drop is handled at the ContentView level (whole window), NOT here.
// - InputMorphView receives attachments as @Binding — ContentView owns the state.
// - appendFiles() is an internal helper used by the paperclip button only.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - InputMorphView

struct InputMorphView: View {

    // MARK: - Inputs

    @Binding var prompt: String
    /// Pending file attachments — owned by ContentView, shared via @Binding.
    @Binding var attachments: [AttachedFile]
    let isWorkspaceSelected: Bool

    /// CPU-13: isolated streaming state — read directly, not via ViewModel.
    let streaming: StreamingState

    let onSend: ([AttachedFile]) -> Void
    let onCancel: () -> Void

    // MARK: - Private State

    @State private var isEditorFocused: Bool = false
    @State private var editorHeight: CGFloat = InputLayout.minEditorHeight
    @State private var editorCoordinator: ChappieTextEditorView.Coordinator?
    @State private var showEmojiPicker: Bool = false

    // MARK: - Computed

    private var canSend: Bool {
        let hasText = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !attachments.isEmpty
        return (hasText || hasAttachments) && isWorkspaceSelected && !streaming.isThinking
    }

    /// CPU-14: morph-only animation token — does NOT include editorHeight.
    /// editorHeight changes on every keystroke → including it here caused a spring
    /// animation loop on every character (60fps timer-driven → 100% CPU while typing).
    /// Editor height is animated separately via a dedicated .animation on its .frame.
    private var morphToken: Int {
        var hasher = Hasher()
        hasher.combine(streaming.isThinking)
        hasher.combine(attachments.isEmpty)
        return hasher.finalize()
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // IDLE: VStack grows naturally — no fixed frame height on the ZStack.
            idleView
                .opacity(streaming.isThinking ? 0 : 1)
                .scaleEffect(streaming.isThinking ? 0.96 : 1, anchor: .bottom)

            // THINKING: fixed collapsedHeight, centered in the capsule.
            // Rendered conditionally — ThinkingGearIcon has a repeating symbolEffect
            // that runs even at opacity:0, costing ~10% CPU idle. Guard it here.
            if streaming.isThinking {
                thinkingView
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(height: InputLayout.collapsedHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 16)
        // CPU-14: only morph transitions are animated at root level (thinking↔idle, attachments appear).
        // editorHeight is NOT in morphToken — typing no longer triggers this spring.
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: morphToken)
        // CPU-16: onHeightChange callback REMOVED.
        // ContentView no longer tracks bottomPanelHeight — uses InputLayout.maxPanelHeight instead.
        // This eliminates the layout pass chain: editorHeight → ContentView state → ChatScrollView.
        .onChange(of: streaming.isThinking) { _, nowThinking in
            if !nowThinking {
                // Small delay lets the morph animation finish before focusing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    editorCoordinator?.focus()
                }
            }
        }
        .onChange(of: prompt) { _, newValue in
            // When prompt is cleared externally (after send) — reset editor height immediately.
            if newValue.isEmpty {
                editorHeight = InputLayout.minEditorHeight
            }
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                AttachmentChipsRow(attachments: attachments) { id in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        attachments.removeAll { $0.id == id }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                ChappieTextEditorView(
                    text: $prompt,
                    isEnabled: isWorkspaceSelected && !streaming.isThinking,
                    onSend: { if canSend { triggerSend() } },
                    onHeightChange: { newHeight in
                        // Only update while not thinking — avoids fighting the collapse animation.
                        // CPU-14: animate height change separately so it doesn't pollute morphToken.
                        if !streaming.isThinking, abs(newHeight - editorHeight) > 1 {
                            withAnimation(.linear(duration: 0.08)) {
                                editorHeight = newHeight
                            }
                        }
                    },
                    onFocusChange: { focused in
                        isEditorFocused = focused
                    },
                    onCoordinatorReady: { coordinator in
                        editorCoordinator = coordinator
                    }
                )
                // CPU-14: .frame animation is LOCAL to the editor — does not trigger root spring.
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
                            .padding(.vertical, InputLayout.editorVerticalPadding)
                            .allowsHitTesting(false)
                    }
                }

                Button(action: openFilePicker) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 16))
                            .frame(width: 28, height: 28)

                        if !attachments.isEmpty {
                            Text("\(attachments.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 4, y: -4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Прикрепить файл")
                .padding(.bottom, 2)

                Button(action: { showEmojiPicker.toggle() }) {
                    Text("😊")
                        .font(.system(size: 18))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Вставить эмодзи")
                .popover(isPresented: $showEmojiPicker, arrowEdge: .top) {
                    EmojiPickerView { emoji in
                        prompt += emoji
                        showEmojiPicker = false
                    }
                }
                .padding(.bottom, 2)

                Button(action: triggerSend) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Thinking View

    private var thinkingView: some View {
        HStack(spacing: 12) {
            // isActive: true because thinkingView is only rendered when streaming.isThinking == true.
            // No need to pass the flag — the view's existence IS the gate.
            ThinkingGearIcon(isActive: true)

            Text(streaming.currentToolCall ?? "Думаю…")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: streaming.currentToolCall)

            Spacer()

            Button(action: onCancel) {
                Label("Отмена", systemImage: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Прервать текущий запрос")
        }
        .frame(height: InputLayout.collapsedHeight)
    }

    // MARK: - Private Helpers

    private func triggerSend() {
        let pending = attachments
        onSend(pending)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            attachments = []
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Выбери файлы для прикрепления"
        panel.prompt = "Прикрепить"

        guard panel.runModal() == .OK else { return }

        let newFiles = panel.urls.compactMap { AttachedFile.load(from: $0) }
        let existingNames = Set(attachments.map(\.filename))
        let unique = newFiles.filter { !existingNames.contains($0.filename) }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            attachments.append(contentsOf: unique)
        }
    }
}

// MARK: - Preview

#Preview("Idle — empty") {
    let streaming = StreamingState()
    return VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            attachments: .constant([]),
            isWorkspaceSelected: true,
            streaming: streaming,
            onSend: { _ in },
            onCancel: {}
        )
    }
    .frame(width: 600, height: 160)
}

#Preview("Idle — multiline") {
    let streaming = StreamingState()
    return VStack {
        Spacer()
        InputMorphView(
            prompt: .constant("Строка 1\nСтрока 2\nСтрока 3\nСтрока 4\nСтрока 5"),
            attachments: .constant([]),
            isWorkspaceSelected: true,
            streaming: streaming,
            onSend: { _ in },
            onCancel: {}
        )
    }
    .frame(width: 600, height: 260)
}

#Preview("Thinking — tool call") {
    let streaming = StreamingState()
    streaming.isThinking = true
    streaming.currentToolCall = "write_file → Chappie/Views/Input/InputMorphView.swift"
    return VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            attachments: .constant([]),
            isWorkspaceSelected: true,
            streaming: streaming,
            onSend: { _ in },
            onCancel: {}
        )
    }
    .frame(width: 600, height: 120)
}
