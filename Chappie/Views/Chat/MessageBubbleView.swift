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
// BUBBLE WIDTH STRATEGY:
// No GeometryReader. No environment width injection.
// The native SwiftUI approach:
//   - HStack with Spacer(minLength: 40) on the opposite side pushes the bubble
//     to at most ~75% of available width organically.
//   - .frame(maxWidth: .infinity) lets the bubble fill its side of the HStack.
//   - The window can resize freely — no measured value creates a minimum-width floor.
//
// IMAGE GRID:
// LazyVGrid is wrapped in a fixed-column layout (up to 3 × 80pt cells).
// It does NOT expand the bubble — the grid is constrained by the bubble's own width.

import SwiftUI
import QuickLook

// MARK: - MessageBubbleView

/// Visual representation of a text message in the chat history.
///
/// Renders only `.message` — a bubble with text from the user or from Chappie.
/// Chappie's bubble uses MarkdownTextView for code and formatting support.
/// User's bubble uses plain Text — users don't write markdown.
struct MessageBubbleView: View {

    let msg: ChatMessage

    var body: some View {
        // Render only .message. .toolCall entries don't reach this component.
        if case .message(_, let isUser, let text, let cost, _, let attachments) = msg {
            messageBubble(isUser: isUser, text: text, cost: cost, attachments: attachments)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
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
        HStack(alignment: .bottom, spacing: 8) {
            // Push user bubble to the right
            if isUser { Spacer(minLength: 40) }

            if isUser {
                // USER BUBBLE
                // .frame(maxWidth: .infinity) + Spacer(minLength:40) on the left
                // naturally limits the bubble to ~75% width without any measurement.
                VStack(alignment: .trailing, spacing: 6) {
                    if !attachments.isEmpty {
                        AttachmentsView(attachments: attachments, isUser: true)
                    }
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            // horizontal: false — text wraps, never pushes bubble wider
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                        if !attachments.isEmpty {
                            AttachmentsView(attachments: attachments, isUser: false)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

            // Push Chappie bubble to the left
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
private struct AttachmentsView: View {

    let attachments: [AttachedFile]
    let isUser: Bool

    @State private var previewURL: URL? = nil

    private var images: [AttachedFile] { attachments.filter { $0.mimeType.isImage } }
    private var files:  [AttachedFile] { attachments.filter { !$0.mimeType.isImage } }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if !images.isEmpty {
                // Fixed 80pt columns, up to 3 per row.
                // The grid is constrained by the bubble width — it does NOT
                // expand the bubble. Images are clipped to their cell frame.
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(80), spacing: 6),
                        count: min(images.count, 3)
                    ),
                    spacing: 6
                ) {
                    ForEach(images) { file in
                        ImageThumbnailView(file: file) {
                            previewURL = writeTempFile(file)
                        }
                    }
                }
                // Prevent the grid from reporting an ideal width larger than its container.
                // fixedSize(horizontal: false) means: "don't ask for more width than given".
                .fixedSize(horizontal: false, vertical: true)
                .quickLookPreview($previewURL)
            }

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

/// Compact chip: icon + filename, used for non-image attachments.
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

// MARK: - FlowLayout

/// Simple left-to-right wrapping layout for file chips.
private struct FlowLayout: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                totalHeight += currentRowHeight + spacing
                currentX = 0
                currentRowHeight = 0
            }
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += currentRowHeight + spacing
                currentX = bounds.minX
                currentRowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
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
    let samplePDF = AttachedFile(filename: "requirements.pdf", mimeType: .pdf, data: Data())
    let sampleTxt = AttachedFile(filename: "notes.txt", mimeType: .plainText, data: Data())

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
                attachments: [sampleImage]
            ))
            MessageBubbleView(msg: .message(
                isUser: true,
                text: "Check these out",
                attachments: [samplePDF, sampleTxt]
            ))
            MessageBubbleView(msg: .message(
                isUser: false,
                text: "## Analysis\n\nThe spec looks **solid**.",
                cost: 1.23
            ))
        }
        .padding()
    }
    .frame(width: 650, height: 800)
    .background(Color(NSColor.windowBackgroundColor))
}
