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
// SCROLLBAR NOTE:
// - NSScrollView vertical scroller is intentionally DISABLED (hasVerticalScroller = false).
//   The panel height is fully controlled by our editorHeight state — the scrollbar is
//   redundant AND causes a layout jitter: macOS reserves width for it before hiding,
//   which makes the text field width jump as the user types. Removing it fixes this.
//
// MULTIMODAL (MULTIMODAL-STEP2):
// - Paperclip button opens NSOpenPanel (images, PDF, text, any file).
// - attachments: [AttachedFile] is a @Binding from ContentView — NOT local @State.
// - AttachmentChipsView renders above the text editor when attachments are non-empty.
// - Each chip shows a thumbnail (images) or icon (other types) + filename + ✕ button.
// - onSend now receives ([AttachedFile]) → caller is responsible for consuming them.
// - No pre-filtering by model capability: we send everything and handle API errors gracefully.
//
// LAYOUT NOTE (ATTACHMENT CHIPS):
// - Chips row lives INSIDE the VStack above the editor row.
// - The outer ZStack does NOT have a fixed frame height — it grows naturally with content.
// - Only the thinkingView uses collapsedHeight (via its own fixed frame).
// - editorHeight controls only ChappieTextEditorView's height, not the whole panel.
// - This prevents the "chips overflow above panel" bug when the editor grows tall.
//
// DRAG & DROP (DND-GLOBAL):
// - Drop is handled at the ContentView level (whole window), NOT here.
// - InputMorphView receives attachments as @Binding — ContentView owns the state.
// - appendFiles() is an internal helper used by the paperclip button only.
// - isDragTargeted and the drop overlay live in ContentView's mainChatArea ZStack.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

// MARK: - Emoji Data

/// All emoji categories shown in the picker popover.
private struct EmojiCategory {
    let icon: String
    let name: String
    let emojis: [String]
}

private let emojiCategories: [EmojiCategory] = [
    EmojiCategory(icon: "⭐️", name: "Частые", emojis: [
        "😀","😂","🥹","😍","🤔","😎","🥳","😅","🙏","👍",
        "❤️","🔥","✅","🚀","💡","🎉","👀","💪","🤝","✨"
    ]),
    EmojiCategory(icon: "😀", name: "Смайлики", emojis: [
        "😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃",
        "😉","😊","😇","🥰","😍","🤩","😘","😗","😚","😙",
        "🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫",
        "🤔","🤐","🤨","😐","😑","😶","😏","😒","🙄","😬",
        "🤥","😌","😔","😪","🤤","😴","😷","🤒","🤕","🥴",
        "😵","🤯","🤠","🥸","😎","🤓","🧐","😕","😟","🙁",
        "😮","😯","😲","😳","🥺","🥹","😦","😧","😨","😰",
        "😥","😢","😭","😱","😖","😣","😞","😓","😩","😫",
        "🥱","😤","😡","😠","🤬","😈","👿","💀","☠️","🤡"
    ]),
    EmojiCategory(icon: "👍", name: "Жесты", emojis: [
        "👍","👎","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙",
        "👈","👉","👆","🖕","👇","☝️","✋","🤚","🖐","🖖",
        "👋","💪","🦾","✍️","🤝","🙌","👏","🫶","🤲","🙏",
        "✊","👊","🤛","🤜","👐","🫴","🫳","🫵","🤙","🫱"
    ]),
    EmojiCategory(icon: "❤️", name: "Сердечки", emojis: [
        "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔",
        "❤️‍🔥","❤️‍🩹","❣️","💕","💞","💓","💗","💖","💘","💝",
        "💟","☮️","✝️","☯️","🫀","💌","💋","🫦","😻","💑"
    ]),
    EmojiCategory(icon: "🐶", name: "Животные", emojis: [
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯",
        "🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐔","🐧",
        "🐦","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝",
        "🐛","🦋","🐌","🐞","🐜","🦟","🦗","🐢","🐍","🦎"
    ]),
    EmojiCategory(icon: "🍕", name: "Еда", emojis: [
        "🍕","🍔","🌮","🌯","🥙","🧆","🥚","🍳","🥘","🍲",
        "🍜","🍝","🍛","🍣","🍱","🥟","🦪","🍤","🍙","🍚",
        "🍘","🍥","🥮","🍡","🧁","🍰","🎂","🍮","🍭","🍬",
        "🍫","🍿","🍩","🍪","🌰","🥜","🍯","🧃","🥤","🧋"
    ]),
    EmojiCategory(icon: "🚀", name: "Символы", emojis: [
        "✅","❌","⭕️","🔴","🟠","🟡","🟢","🔵","🟣","⚫️",
        "⚪️","🟤","🔶","🔷","🔸","🔹","🔺","🔻","💠","🔘",
        "🔲","🔳","▪️","▫️","◾","◽","◼️","◻️","🟥","🟧",
        "🚀","💡","🔥","⚡️","💥","🌟","✨","🎉","🎊","🏆",
        "🥇","🎯","🎪","🎭","🎨","🖼","🎬","🎤","🎧","🎵"
    ])
]

// MARK: - Emoji Picker Popover

/// Grid-based emoji picker shown in a popover above the input bar.
private struct EmojiPickerView: View {

    let onSelect: (String) -> Void

    @State private var selectedCategory = 0

    // 10 emoji per row, fixed 30pt cells
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 10)

    var body: some View {
        VStack(spacing: 0) {

            // Category tab bar
            HStack(spacing: 0) {
                ForEach(emojiCategories.indices, id: \.self) { index in
                    Button(action: { selectedCategory = index }) {
                        Text(emojiCategories[index].icon)
                            .font(.system(size: 16))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                selectedCategory == index
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            Divider()

            // Emoji grid for the selected category
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(emojiCategories[selectedCategory].emojis, id: \.self) { emoji in
                        Button(action: { onSelect(emoji) }) {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(height: 180)
        }
        .frame(width: 340)
    }
}

// MARK: - Attachment Chip

/// A single chip showing an attached file — thumbnail for images, icon for others.
/// Has an ✕ button to remove it from the pending list.
private struct AttachmentChipView: View {

    let file: AttachedFile
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Thumbnail for images; SF Symbol icon for other types
            if let image = file.nsImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: file.mimeType.systemIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }

            // Truncated filename — chips can be narrow
            Text(file.filename)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Убрать вложение")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - Attachment Chips Row

/// Horizontal scrollable row of attachment chips shown above the text editor.
/// Only rendered when attachments is non-empty.
private struct AttachmentChipsRow: View {

    let attachments: [AttachedFile]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { file in
                    AttachmentChipView(file: file) {
                        onRemove(file.id)
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: attachments.map(\.id))
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
        // Vertical scroller is intentionally OFF — the panel height is managed by editorHeight
        // state, so a scrollbar is redundant. More importantly: when autohidesScrollers = true,
        // macOS still reserves space for the scrollbar before hiding it, which causes the text
        // field width to jitter as the user types. Disabling it entirely eliminates the jitter.
        scrollView.hasVerticalScroller = false
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

// MARK: - Thinking Gear Icon

/// Spinning gear icon for the thinking state.
/// Uses .rotate symbolEffect on macOS 15+, falls back to opacity pulse on macOS 14.
private struct ThinkingGearIcon: View {
    @State private var pulsing = false

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                // Rotation signals active processing — available macOS 15+
                .symbolEffect(.rotate, options: .repeating)
        } else {
            // macOS 14 fallback: gentle opacity pulse
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
        }
    }
}

// MARK: - InputMorphView

struct InputMorphView: View {

    // MARK: - Inputs

    @Binding var prompt: String
    /// Pending file attachments — owned by ContentView, shared via @Binding.
    /// ContentView's whole-window drop target writes to this binding directly.
    /// InputMorphView reads it for display and clears it on send.
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
    @State private var editorHeight: CGFloat = Layout.minEditorHeight
    @State private var editorCoordinator: ChappieTextEditorView.Coordinator?
    /// Controls the emoji picker popover visibility.
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
                .frame(height: isThinking ? Layout.collapsedHeight : 0)
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
                editorHeight = Layout.minEditorHeight
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
                            .padding(.vertical, Layout.editorVerticalPadding)
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

                // Emoji picker button — sits between the text field and the send button.
                // Opens a popover with 7 categories. Tapping an emoji appends it to the prompt.
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
        .frame(height: Layout.collapsedHeight)
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
