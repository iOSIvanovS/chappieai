// MessageBubbleView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Renders individual chat message bubbles in the conversation scroll view.
//
// BUBBLE WIDTH STRATEGY:
// frame(maxWidth: .infinity) on the HStack row, then frame(maxWidth: bubbleMaxWidth)
// on the bubble itself. bubbleMaxWidth is a fixed point value (500 pt) — no GeometryReader,
// no containerRelativeFrame, no background probes. Simple and correct.
//
// ATTACHMENTS STRATEGY (simplified, IT-14 rev2):
// Replaced FlowLayout thumbnails with a plain vertical list (AttachmentRowView).
// Each attachment is one row: icon + filename + file size.
// Images open via QuickLook on click. Other files open via NSWorkspace.
// Benefits: no layout complexity, no GeometryReader, window can resize freely.

import SwiftUI
import QuickLook

// Fixed maximum bubble width in points.
// Works well for typical macOS window sizes (800–1400 pt wide).
private let bubbleMaxWidth: CGFloat = 500

// MARK: - MessageBubbleView (public entry point)

/// Renders a single chat message bubble.
/// No GeometryReader, no background probes — just HStack + Spacer.
struct MessageBubbleView: View {

    let msg: ChatMessage

    var body: some View {
        if case .message(_, let isUser, let text, let cost, _, let attachments) = msg {
            messageBubble(isUser: isUser, text: text, cost: cost, attachments: attachments)
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
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 24) }

            if isUser {
                userBubble(text: text, attachments: attachments)
            } else {
                chappieBubble(text: text, cost: cost, attachments: attachments)
            }

            if !isUser { Spacer(minLength: 24) }
        }
        // Smooth slide-in from bottom on insertion, fade on removal.
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            )
        )
        .id(msg.id)
    }

    // MARK: - User Bubble

    @ViewBuilder
    private func userBubble(text: String, attachments: [AttachedFile]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                AttachmentListView(attachments: attachments, isUser: true)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    // Allow text to wrap naturally — no fixed width needed.
                    .fixedSize(horizontal: false, vertical: true)
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
        // Shrinks to content, hard cap at bubbleMaxWidth.
        .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
    }

    // MARK: - Chappie Bubble

    @ViewBuilder
    private func chappieBubble(text: String, cost: Double?, attachments: [AttachedFile]) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty {
                    AttachmentListView(attachments: attachments, isUser: false)
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
        .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
    }
}

// MARK: - AttachmentListView

/// Vertical list of attachment rows.
/// Each row: file icon + filename + file size.
/// Images open via QuickLook. Other files open via NSWorkspace.
/// No FlowLayout, no GeometryReader, no fixed widths — pure VStack.
private struct AttachmentListView: View {

    let attachments: [AttachedFile]
    let isUser: Bool

    @State private var previewURL: URL? = nil

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(attachments) { file in
                AttachmentRowView(file: file, isUser: isUser) {
                    if file.mimeType.isImage {
                        // Write to temp dir and open QuickLook.
                        previewURL = writeTempFile(file)
                    } else {
                        // Open with default app.
                        if let url = writeTempFile(file) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func writeTempFile(_ file: AttachedFile) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(file.filename)
        try? file.data.write(to: url)
        return url
    }
}

// MARK: - AttachmentRowView

/// Single attachment row: icon + filename + size.
/// Tapping triggers the onTap action (QuickLook or NSWorkspace).
private struct AttachmentRowView: View {

    let file: AttachedFile
    let isUser: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                // File type icon — image files get a photo icon.
                Image(systemName: file.mimeType.isImage ? "photo" : file.mimeType.systemIcon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)

                // Filename — truncates in the middle to preserve extension.
                Text(file.filename)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // File size — compact human-readable format.
                Text(fileSizeString(file.data.count))
                    .font(.system(size: 11))
                    .opacity(0.65)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isUser
                    ? Color.white.opacity(0.18)
                    : Color.primary.opacity(0.06)
            )
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open \(file.filename)")
    }

    /// Human-readable file size: "42 B", "1.2 KB", "3.4 MB".
    private func fileSizeString(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}

// MARK: - Preview

#Preview("Messages with attachments") {
    let sampleImage = AttachedFile(
        filename: "screenshot.png",
        mimeType: .imagePng,
        data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==")!
    )
    let samplePDF  = AttachedFile(filename: "requirements.pdf", mimeType: .pdf, data: Data(count: 204800))
    let sampleTxt  = AttachedFile(filename: "very_long_filename_that_should_truncate_in_the_middle.txt", mimeType: .plainText, data: Data(count: 1536))

    return ScrollView {
        VStack(spacing: 16) {
            MessageBubbleView(msg: .message(
                isUser: true,
                text: "Here's the screenshot and the spec",
                attachments: [sampleImage, samplePDF]
            ))
            MessageBubbleView(msg: .message(
                isUser: false,
                text: "Got it! I'll analyze both files.",
                cost: 0.45
            ))
            MessageBubbleView(msg: .message(
                isUser: true,
                text: "",
                attachments: [sampleImage, sampleImage, sampleImage, sampleImage, sampleImage]
            ))
            MessageBubbleView(msg: .message(
                isUser: true,
                text: "Check these notes",
                attachments: [sampleTxt]
            ))
            MessageBubbleView(msg: .message(
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
