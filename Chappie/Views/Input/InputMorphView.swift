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
//   capped at maxLines, with spring animation.
// - On send: editorHeight resets to minEditorHeight immediately; morph animates to collapsedHeight.
// - On finish/cancel: height restores from editorHeight; editor auto-focuses via coordinator.
//
// SCROLL INTEGRATION:
// - onHeightChange callback fires whenever the panel's total rendered height changes.
// - ContentView uses this to set bottomPadding on ChatScrollView, so the last message
//   is never hidden under the panel — on launch, on grow, or on collapse.
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
    /// ContentView's whole-window drop target writes to this binding directly.
    @Binding var attachments: [AttachedFile]
    let isWorkspaceSelected: Bool
    let isThinking: Bool
    let currentToolCall: String?
    let onSend: ([AttachedFile]) -> Void
    let onCancel: () -> Void

    /// Called whenever the panel's total rendered height changes.
    /// ContentView uses this to update ChatScrollView's bottom padding.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    // MARK: - Private State

    @State private var isEditorFocused: Bool = false
    @State private var editorHeight: CGFloat = InputLayout.minEditorHeight
    @State private var editorCoordinator: ChappieTextEditorView.Coordinator?
    @State private var showEmojiPicker: Bool = false

    // MARK: - Computed

    private var canSend: Bool {
        let hasText = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !attachments.isEmpty
        // Allow sending if there's text OR attachments (or both)
        return (hasText || hasAttachments)
            && isWorkspaceSelected
            && !isThinking
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // IDLE: VStack grows naturally — no fixed frame height on the ZStack.
            // editorHeight controls only ChappieTextEditorView, not the whole panel.
            // This is the fix for the "chips overflow above panel" bug.
            idleView
                .opacity(isThinking ? 0 : 1)
                .scaleEffect(isThinking ? 0.96 : 1, anchor: .bottom)

            // THINKING: fixed collapsedHeight, centered in the capsule
            thinkingView
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                // Adaptive background — controlBackgroundColor switches correctly in dark mode
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(isThinking ? 1 : 0)
                .scaleEffect(isThinking ? 1 : 0.96, anchor: .bottom)
                // Thinking view always occupies collapsedHeight — no layout influence when hidden
                .frame(height: isThinking ? InputLayout.collapsedHeight : 0)
        }
        .padding(12)
        // ultraThinMaterial gives the frosted-glass look matching the toolbar above
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isThinking)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: editorHeight)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: attachments.isEmpty)
        // Report total rendered height via GeometryReader so ChatScrollView can pad correctly.
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
                editorHeight = InputLayout.minEditorHeight
            }
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Attachment chips row — only visible when files are attached.
            // Rendered INSIDE the VStack so it contributes to natural panel height growth.
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
                    isEnabled: isWorkspaceSelected && !isThinking,
                    onSend: { if canSend { triggerSend() } },
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
                            .padding(.vertical, InputLayout.editorVerticalPadding)
                            .allowsHitTesting(false)
                    }
                }

                // Paperclip button — opens NSOpenPanel for file picking.
                // Badge shows count when files are attached.
                Button(action: openFilePicker) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 16))
                            .frame(width: 28, height: 28)

                        // Attachment count badge — visible when files are pending
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

                // Emoji picker button — opens a popover with 7 categories.
                // Tapping an emoji appends it to the prompt.
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
            // Animated gear icon — macOS 15+ uses .rotate, macOS 14 uses opacity pulse
            ThinkingGearIcon()

            Text(currentToolCall ?? "Думаю…")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
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
            .help("Прервать текущий запрос")
        }
        .frame(height: InputLayout.collapsedHeight)
    }

    // MARK: - Private Helpers

    /// Fires the send callback with current attachments, then clears them.
    private func triggerSend() {
        let pending = attachments
        onSend(pending)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            attachments = []
        }
    }

    /// Opens NSOpenPanel allowing any file type.
    /// Loaded files are appended to the pending attachments list (via binding).
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
    VStack {
        Spacer()
        InputMorphView(
            prompt: .constant(""),
            attachments: .constant([]),
            isWorkspaceSelected: true,
            isThinking: false,
            currentToolCall: nil,
            onSend: { _ in },
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
            attachments: .constant([]),
            isWorkspaceSelected: true,
            isThinking: false,
            currentToolCall: nil,
            onSend: { _ in },
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
            attachments: .constant([]),
            isWorkspaceSelected: true,
            isThinking: true,
            currentToolCall: "write_file → Chappie/Views/Input/InputMorphView.swift",
            onSend: { _ in },
            onCancel: {}
        )
    }
    .frame(width: 600, height: 120)
}
