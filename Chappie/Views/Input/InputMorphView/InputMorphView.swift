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
//   capped at maxLines. NO animation on height — height jumps are instant and imperceptible
//   at normal typing speed. withAnimation here was firing a display link on every keystroke.
// - On send: editorHeight resets to minEditorHeight immediately.
// - On finish/cancel: height restores from editorHeight; editor auto-focuses via coordinator.
//
// FOOTER HEIGHT STRATEGY (CPU-22):
// ContentView measures the actual rendered height of InputMorphView via onGeometryChange
// and passes it to ChatScrollView as footerHeight. This is exact regardless of content
// (attachment row, multi-line text, thinking state). No manual math needed here.
//
// CPU-10: THREE ANIMATIONS → ONE TOKEN (morph-only):
// - Previously three separate .animation(..., value:) modifiers were stacked on the root view.
// - Fix: animationToken combines ONLY isThinking + attachments.isEmpty.
//   editorHeight has NO animation at all — instant, imperceptible, zero cost.
//   Morph (thinking↔idle) still gets the full spring. Typing no longer triggers any animation.
//
// CPU-13: STREAMING ISOLATION:
// - InputMorphView receives `streaming: StreamingState` instead of separate isThinking
//   and currentToolCall parameters. It reads streaming.isThinking and streaming.currentToolCall
//   directly — subscribing to StreamingState, NOT to ViewModel.
//
// CPU-23: currentToolCall is throttled to 200ms in StreamingState.
//
// CPU-29: .animation(.easeInOut, value: currentToolCall) removed from toolCall Text.
// Even with 200ms throttle, SwiftUI cross-fade animation runs two render passes
// simultaneously (old text + new text) on every tool call update.
// Text simply updates instantly — imperceptible at 200ms cadence, zero render cost.
//
// CPU-30: ThinkingGearIcon (TimelineView-based) replaced with ProgressView().
// ProgressView on macOS wraps NSProgressIndicator — animated via CoreAnimation/GPU,
// CPU cost ≈ 0%. TimelineView was the confirmed culprit of ~25% idle CPU.
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

    @State var isEditorFocused: Bool = false
    @State var editorHeight: CGFloat = InputLayout.minEditorHeight
    @State var editorCoordinator: ChappieTextEditorView.Coordinator?
    @State var showEmojiPicker: Bool = false

    // MARK: - Computed

    var canSend: Bool {
        let hasText = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !attachments.isEmpty
        return (hasText || hasAttachments) && isWorkspaceSelected && !streaming.isThinking
    }

    /// Morph-only animation token — combines ONLY isThinking + attachments.isEmpty.
    /// editorHeight is intentionally excluded: animating height on every keystroke
    /// fires a display link for 80ms per character → 100% CPU while typing.
    var morphToken: Int {
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

            // THINKING: rendered conditionally — ProgressView lifecycle is managed by SwiftUI.
            // No idle cost when not thinking.
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
        // Only morph transitions are animated (thinking↔idle, attachments appear/disappear).
        // editorHeight is NOT in morphToken — typing triggers zero animation.
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: morphToken)
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
}
