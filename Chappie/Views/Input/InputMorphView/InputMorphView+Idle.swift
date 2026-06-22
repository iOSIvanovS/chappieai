// InputMorphView+Idle.swift
// Chappie
//
// Idle state UI: text editor, paperclip, emoji picker, send button.

import SwiftUI
import AppKit

extension InputMorphView {

    // MARK: - Idle View

    var idleView: some View {
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
                        // Instant update — no animation. Height jumps are imperceptible at
                        // normal typing speed and withAnimation here fires a 80ms display link
                        // on every keystroke. CPU-18: coordinator cache fires only on line count change.
                        guard !streaming.isThinking, abs(newHeight - editorHeight) > 1 else { return }
                        editorHeight = newHeight
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
                        Text("input.placeholder")
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
                            Text(verbatim: "\(attachments.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 4, y: -4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("input.attach_file")
                .padding(.bottom, 2)

                Button(action: { showEmojiPicker.toggle() }) {
                    Text(verbatim: "😊")
                        .font(.system(size: 18))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("input.emoji")
                .popover(isPresented: $showEmojiPicker, arrowEdge: .top) {
                    EmojiPickerView { emoji in
                        // Insert at cursor position via NSTextView, not string append.
                        // prompt += emoji was always appending to the end, ignoring cursor.
                        editorCoordinator?.insertAtCursor(emoji)
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
}
