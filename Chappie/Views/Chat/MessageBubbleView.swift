// MessageBubbleView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Formerly MessageBubble was a private struct inside ContentView.swift.
// Extracted to a separate file to:
//   1. Keep ContentView from becoming a monolith
//   2. Allow reuse (e.g. in search or preview)
//   3. Isolate the visual bubble logic so it's easy to change
//
// CHANGE (Stage 6 — ТД-6):
// MessageBubbleView now takes a typed enum ChatMessage instead of a struct.
//
// CHANGE (ТД-UX-PERF — UI performance optimization):
// .toolCall is completely removed from this component's render.
// .toolCall entries no longer appear in the feed — they are shown in StatusBarView.
// MessageBubbleView now renders ONLY .message (text messages).
//
// CHANGE (ТД-COST-SUMMARY — Self-Summary):
// .message case gained a 5th field `summary: String?`.
// Destructuring pattern updated — `_` added for summary.
//
// CHANGE (UX-ANIMATION — Smooth bubble appearance):
// Added .transition on the bubble: new messages smoothly slide in from the bottom
// with simultaneous fade-in.
//
// CHANGE (UX-TYPOGRAPHY — Typography and Markdown):
// Chappie's bubble now uses MarkdownTextView instead of Text():
//   - Code blocks in Xcode Intelligence Panel style (dark background, Swift highlighting)
//   - Inline code, bold, italic, headings
//   - SF Pro Text 14pt, lineSpacing 5 (Apple HIG: 1.3–1.5× line-height)
//   - Copy button in code blocks
//
// CHANGE (UX-COST-IN-BUBBLE — Cost inside bubble):
// Cost moved from below the bubble INTO it — bottom-trailing corner.
// Uses ZStack(alignment: .bottomTrailing) + padding(.bottom, 18) under the text.
// Shown only for Chappie messages (isUser == false) with known cost.
// Standard messenger UX pattern (WhatsApp, Telegram) — time/status inside.
//
// CHANGE (MULTIMODAL — Step 4):
// Attachments are now rendered inside the bubble:
//   - Images: inline thumbnails in a wrapping flow grid, tap → full-size QuickLook sheet
//   - Non-image files: compact chips with icon + filename
// Layout: attachments appear ABOVE the text (natural reading order — see attachment, then message).
// For user bubbles: accent-tinted chip background to match bubble color.
// For Chappie bubbles: secondary background chip.
//
// BUBBLE DESIGN (Apple HIG + macOS 26):
// User: accent color (blue), white text — "our" messages
// Chappie: clean background with thin border, like macOS 26 cards — neutral
// Both bubbles: cornerRadius 12, shadow 0.1 opacity — light, not aggressive
//
// IMAGE ATTACHMENT WIDTH FIX:
// LazyVGrid with fixed-width columns was expanding the bubble to fit the grid width.
// Fix: images are now rendered as a plain HStack with fixed 80×80 thumbnails,
// wrapped in .fixedSize(horizontal: false, vertical: true) so the grid never
// forces the bubble wider than its natural text content.
//
// FLOW LAYOUT (IT-14):
// FlowLayout for file chips moved to Shared/FlowLayout.swift — shared with ProjectChipsView.
// The private duplicate has been removed from this file.

import SwiftUI
import QuickLook

/// Visual representation of a text message in the chat history.
///
/// Renders only `.message` — a bubble with text from the user or from Chappie.
/// Chappie's bubble uses MarkdownTextView for code and formatting support.
/// User's bubble uses plain Text — users don't write markdown.
struct MessageBubbleView: View {

    let msg: ChatMessage

    var body: some View {
        // Render only .message. .toolCall entries don't reach this component.
        // IMPORTANT: pattern destructures ALL 6 fields of the .message case:
        //   id, isUser, text, cost, summary, attachments
        if case .message(_, let isUser, let text, let cost, _, let attachments) = msg {
            messageBubble(isUser: isUser, text: text, cost: cost, attachments: attachments)
                // APPEARANCE ANIMATION:
                // .asymmetric: insertion — slide from bottom + fade, removal — fade only.
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        }
    }

    // MARK: - Bubble Render

    /// Text message bubble with optional attachments.
    @ViewBuilder
    private func messageBubble(
        isUser: Bool,
        text: String,
        cost: Double?,
        attachments: [AttachedFile]
    ) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            if isUser {
                // USER BUBBLE
                VStack(alignment: .trailing, spacing: 6) {
                    // Attachments above the text.
                    // fixedSize(horizontal: false) prevents the attachment grid from
                    // expanding the bubble beyond its natural text width.
                    if !attachments.isEmpty {
                        AttachmentsView(attachments: attachments, isUser: true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 12,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 12
                    )
                )
            } else {
                // CHAPPIE BUBBLE
                ZStack(alignment: .bottomTrailing) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Attachments above the text
                        if !attachments.isEmpty {
                            AttachmentsView(attachments: attachments, isUser: false)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !text.isEmpty {
                            MarkdownTextView(text: text, fontSize: 14)
                                // Reserve space for cost badge when present
                                .padding(.bottom, cost != nil ? 18 : 0)
                        }
                    }

                    // Cost badge — bottom-trailing corner
                    if let cost = cost {
                        Text(String(format: "🪙 %.2f ₽", cost))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12
                    )
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            if !isUser { Spacer(minLength: 40) }
        }
        .id(msg.id)
    }
}

// MARK: - AttachmentsView

/// Renders a list of attachments: image thumbnails + file chips.
///
/// Images are shown as a wrapping row of thumbnails (tap → full preview).
/// Non-image files are shown as compact chips with icon + filename.
///
/// WHY NO LazyVGrid HERE:
/// LazyVGrid with fixed columns forces itself to its declared width regardless of content.
/// This was causing the user bubble to expand to fit the grid even when the text was short.
/// Plain HStack wrapping is used instead — the bubble stays as wide as its content.
private struct AttachmentsView: View {

    let attachments: [AttachedFile]
    let isUser: Bool

    // Track which image URL is being previewed in QuickLook
    @State private var previewURL: URL? = nil

    private var images: [AttachedFile] { attachments.filter { $0.mimeType.isImage } }
    private var files:  [AttachedFile] { attachments.filter { !$0.mimeType.isImage } }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            // IMAGE THUMBNAILS
            // Rendered as a plain HStack — no LazyVGrid.
            // Each thumbnail is 80×80; HStack wraps naturally without forcing bubble width.
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { file in
                        ImageThumbnailView(file: file) {
                            previewURL = writeTempFile(file)
                        }
                    }
                }
                .quickLookPreview($previewURL)
            }

            // FILE CHIPS — use shared FlowLayout from Shared/FlowLayout.swift
            if !files.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(files) { file in
                        FileChipView(file: file, isUser: isUser)
                    }
                }
            }
        }
    }

    /// Write attachment data to a temp file so QuickLook can open it.
    private func writeTempFile(_ file: AttachedFile) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(file.filename)
        try? file.data.write(to: url)
        return url
    }
}

// MARK: - ImageThumbnailView

/// 80×80 rounded image thumbnail with a subtle border.
/// Tapping calls `onTap` so the parent can open QuickLook.
private struct ImageThumbnailView: View {

    let file: AttachedFile
    let onTap: () -> Void

    var body: some View {
        Group {
            if let image = file.nsImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            } else {
                // Fallback: broken image placeholder
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .onTapGesture { onTap() }
        .help(file.filename)
    }
}

// MARK: - FileChipView

/// Compact chip: icon + filename, used for non-image attachments.
/// Tinted with accent color for user bubbles, secondary for Chappie.
private struct FileChipView: View {

    let file: AttachedFile
    let isUser: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: file.mimeType.systemIcon)
                .font(.system(size: 11, weight: .medium))
            Text(file.filename)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            // User bubble: white at 20% opacity (sits on accent blue).
            // Chappie bubble: primary at 6% opacity (sits on light/dark surface).
            isUser
                ? Color.white.opacity(0.20)
                : Color.primary.opacity(0.06)
        )
        .foregroundStyle(isUser ? Color.white : Color.primary)
        .clipShape(Capsule())
        .help(file.filename)
    }
}

// MARK: - Preview

#Preview("Messages with attachments") {
    let sampleImage = AttachedFile(
        filename: "screenshot.png",
        mimeType: .imagePng,
        // 1×1 white PNG (minimal valid PNG bytes)
        data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==")!
    )
    let samplePDF = AttachedFile(
        filename: "requirements.pdf",
        mimeType: .pdf,
        data: Data()
    )
    let sampleTxt = AttachedFile(
        filename: "notes.txt",
        mimeType: .plainText,
        data: Data()
    )

    return ScrollView {
        VStack(spacing: 16) {
            // User message with image + file
            MessageBubbleView(msg: .message(
                isUser: true,
                text: "Here's the screenshot and the spec",
                attachments: [sampleImage, samplePDF]
            ))

            // Chappie response with no attachments
            MessageBubbleView(msg: .message(
                isUser: false,
                text: "Got it! I'll analyze both files.",
                cost: 0.45
            ))

            // User: image only, no text
            MessageBubbleView(msg: .message(
                isUser: true,
                text: "",
                attachments: [sampleImage]
            ))

            // User: files only
            MessageBubbleView(msg: .message(
                isUser: true,
                text: "Check these out",
                attachments: [samplePDF, sampleTxt]
            ))

            // Chappie with markdown + cost
            MessageBubbleView(msg: .message(
                isUser: false,
                text: "## Analysis\n\nThe spec looks **solid**. Key points:\n- Feature A is well-defined\n- Feature B needs clarification\n\n```swift\nlet x = 42\n```",
                cost: 1.23
            ))
        }
        .padding()
    }
    .frame(width: 650, height: 800)
    .background(Color(NSColor.windowBackgroundColor))
}
