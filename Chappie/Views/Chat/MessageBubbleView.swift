// MessageBubbleView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Formerly MessageBubble was a private struct inside ContentView.swift.
// Extracted to a separate file to keep ContentView clean and allow reuse.
//
// BUBBLE WIDTH STRATEGY — background probe pattern:
//
// PROBLEM: We need the row's available width to:
//   1. Cap bubble width at 75% (frame(maxWidth:) — shrinks to content, not fixed)
//   2. Give FlowLayout a finite maxWidth so thumbnails wrap to 2nd/3rd rows
//
// WHY NOT containerRelativeFrame:
//   containerRelativeFrame(.horizontal) sets EXACT width (like frame(width:)), not maxWidth.
//   Short user messages were always stretched to 75% of the window — looked wrong.
//
// WHY NOT GeometryReader directly in body:
//   GeometryReader takes ALL proposed space. Inside ScrollView's VStack, vertical space
//   is infinite (scroll container). GeometryReader expands to fill the screen →
//   bubbles overlap like playing cards.
//
// SOLUTION — background width probe:
//   MessageBubbleRowView is the public entry point.
//   It renders the bubble normally (natural height) and puts a Color.clear
//   GeometryReader in the .background. Backgrounds are sized AFTER layout —
//   they cannot inflate the parent's size. The measured width is stored in
//   @State and passed into the bubble for FlowLayout calculations.
//   Default value 600 is used on first render (before measurement) — safe fallback.
//
// CHANGE (Stage 6 — ТД-6):
// MessageBubbleView now takes a typed enum ChatMessage instead of a struct.
//
// CHANGE (ТД-UX-PERF — UI performance optimization):
// .toolCall is completely removed from this component's render.
// MessageBubbleView now renders ONLY .message (text messages).
//
// CHANGE (UX-ANIMATION — Smooth bubble appearance):
// Added .transition on the bubble: new messages smoothly slide in from the bottom.
//
// CHANGE (UX-TYPOGRAPHY — Typography and Markdown):
// Chappie's bubble uses MarkdownTextView for code and formatting support.
//
// CHANGE (UX-COST-IN-BUBBLE — Cost inside bubble):
// Cost badge in bottom-trailing corner (WhatsApp/Telegram pattern).
//
// CHANGE (MULTIMODAL — Step 4):
// Attachments rendered inside the bubble above the text.
// Images: FlowLayout thumbnails (wraps to multiple rows).
// Files: compact chips with icon + filename.
//
// FLOW LAYOUT (IT-14):
// FlowLayout shared with ProjectChipsView via Shared/FlowLayout.swift.

import SwiftUI
import QuickLook

// Maximum bubble width as a fraction of the row width.
// Applied as frame(maxWidth:) — bubble shrinks to content, never wider than this cap.
// 0.75 matches Telegram/iMessage proportions.
private let bubbleMaxWidthFraction: CGFloat = 0.75

// MARK: - MessageBubbleRowView (public entry point)

/// Public entry point for rendering a chat message bubble.
///
/// Uses a background Color.clear GeometryReader to measure the row width
/// without affecting layout height. The width is passed into the bubble
/// so FlowLayout can wrap image thumbnails correctly.
struct MessageBubbleRowView: View {

    let msg: ChatMessage

    // Row width measured by the background probe.
    // Default 600: safe fallback for first render before measurement fires.
    @State private var rowWidth: CGFloat = 600

    var body: some View {
        MessageBubbleView(msg: msg, rowWidth: rowWidth)
            .background(
                // WIDTH PROBE: Color.clear in background is sized by the parent AFTER layout.
                // It cannot inflate the parent's size — purely passive measurement.
                // onAppear + onChange cover both initial render and window resize.
                GeometryReader { geo in
                    Color.clear
                        .onAppear { rowWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in rowWidth = w }
                }
            )
            // Smooth slide-in from bottom on insertion, fade on removal.
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                )
            )
    }
}

// MARK: - MessageBubbleView (internal render)

/// Internal bubble renderer. Receives pre-measured rowWidth from MessageBubbleRowView.
struct MessageBubbleView: View {

    let msg: ChatMessage
    // Available row width — used to cap bubble and size FlowLayout.
    let rowWidth: CGFloat

    var body: some View {
        if case .message(_, let isUser, let text, let cost, _, let attachments) = msg {
            messageBubble(
                isUser: isUser,
                text: text,
                cost: cost,
                attachments: attachments
            )
        }
    }

    // MARK: - Bubble Render

    @ViewBuilder
    private func messageBubble(
        isUser: Bool,
        text: String,
        cost: Double?,
        attachments: [AttachedFile]
    ) -> some View {
        // Cap: bubble never wider than 75% of the row.
        // frame(maxWidth:) — shrinks to content, unlike containerRelativeFrame which sets exact width.
        let maxBubbleWidth = rowWidth * bubbleMaxWidthFraction
        // Inner content width: bubble width minus horizontal padding (14×2 = 28).
        let innerWidth = maxBubbleWidth - 28

        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 0) }

            if isUser {
                // USER BUBBLE — accent color, white text
                VStack(alignment: .trailing, spacing: 6) {
                    if !attachments.isEmpty {
                        AttachmentsView(
                            attachments: attachments,
                            isUser: true,
                            maxWidth: innerWidth
                        )
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
                // frame(maxWidth:) — shrinks to content, hard cap at 75%
                .frame(maxWidth: maxBubbleWidth)

            } else {
                // CHAPPIE BUBBLE — neutral background, markdown text
                ZStack(alignment: .bottomTrailing) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !attachments.isEmpty {
                            AttachmentsView(
                                attachments: attachments,
                                isUser: false,
                                maxWidth: innerWidth
                            )
                        }
                        if !text.isEmpty {
                            MarkdownTextView(text: text, fontSize: 14)
                                .padding(.bottom, cost != nil ? 18 : 0)
                        }
                    }

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
                .frame(maxWidth: maxBubbleWidth)
            }

            if !isUser { Spacer(minLength: 0) }
        }
        .id(msg.id)
    }
}

// MARK: - AttachmentsView

/// Renders image thumbnails (FlowLayout) and file chips (FlowLayout).
///
/// maxWidth is passed explicitly so FlowLayout receives a finite proposal
/// and wraps thumbnails onto 2nd, 3rd rows when the bubble is narrow.
private struct AttachmentsView: View {

    let attachments: [AttachedFile]
    let isUser: Bool
    // Bubble inner width (bubble maxWidth minus horizontal padding).
    let maxWidth: CGFloat

    @State private var previewURL: URL? = nil

    private var images: [AttachedFile] { attachments.filter { $0.mimeType.isImage } }
    private var files:  [AttachedFile] { attachments.filter { !$0.mimeType.isImage } }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if !images.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(images) { file in
                        ImageThumbnailView(file: file) {
                            previewURL = writeTempFile(file)
                        }
                    }
                }
                // Explicit width gives FlowLayout a finite proposal → wraps correctly.
                .frame(width: maxWidth, alignment: isUser ? .trailing : .leading)
                .quickLookPreview($previewURL)
            }

            if !files.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(files) { file in
                        FileChipView(file: file, isUser: isUser)
                    }
                }
                .frame(width: maxWidth, alignment: isUser ? .trailing : .leading)
            }
        }
    }

    private func writeTempFile(_ file: AttachedFile) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(file.filename)
        try? file.data.write(to: url)
        return url
    }
}

// MARK: - ImageThumbnailView

/// 80×80 rounded image thumbnail. Tapping opens QuickLook via parent's previewURL.
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

/// Compact chip: icon + filename for non-image attachments.
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
        data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==")!
    )
    let samplePDF = AttachedFile(filename: "requirements.pdf", mimeType: .pdf, data: Data())
    let sampleTxt = AttachedFile(filename: "notes.txt", mimeType: .plainText, data: Data())

    return ScrollView {
        VStack(spacing: 16) {
            MessageBubbleRowView(msg: .message(
                isUser: true,
                text: "Here's the screenshot and the spec",
                attachments: [sampleImage, samplePDF]
            ))
            MessageBubbleRowView(msg: .message(
                isUser: false,
                text: "Got it! I'll analyze both files.",
                cost: 0.45
            ))
            MessageBubbleRowView(msg: .message(
                isUser: true,
                text: "",
                attachments: [sampleImage, sampleImage, sampleImage, sampleImage, sampleImage, sampleImage, sampleImage]
            ))
            MessageBubbleRowView(msg: .message(
                isUser: true,
                text: "Check these out",
                attachments: [samplePDF, sampleTxt]
            ))
            MessageBubbleRowView(msg: .message(
                isUser: false,
                text: "## Analysis\n\nThe spec looks **solid**.\n\n```swift\nlet x = 42\n```",
                cost: 1.23
            ))
        }
        .padding()
    }
    .frame(width: 650, height: 800)
    .background(Color(NSColor.windowBackgroundColor))
}
