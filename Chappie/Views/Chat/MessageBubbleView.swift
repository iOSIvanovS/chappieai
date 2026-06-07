// MessageBubbleView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Renders individual chat message bubbles in the conversation scroll view.
//
// ATTACHMENTS STRATEGY (simplified, IT-14 rev2):
// Replaced FlowLayout thumbnails with a plain vertical list (AttachmentRowView).
// Each attachment is one row: icon + filename + file size.
// All files (images, docs, AI-generated) open via QuickLook on click.
// QuickLook provides native preview + built-in Share button for saving anywhere.
//
// TERMINAL CONFIRMATION (TERMINAL-CONFIRM):
// .terminalConfirmation case renders an inline Run/Cancel prompt.

import SwiftUI
import QuickLook


// MARK: - MessageBubbleView (public entry point)

struct MessageBubbleView: View {

    let msg: ChatMessage
    let availableWidth: CGFloat
    @Environment(ChappieViewModel.self) private var viewModel

    var body: some View {
        switch msg {
        case .message(_, let isUser, let text, let cost, let attachments):
            messageBubble(isUser: isUser, text: text, cost: cost, attachments: attachments)

        case .terminalConfirmation(let id, let command, let threadId):
            terminalConfirmationBubble(id: id, command: command, threadId: threadId)

        case .toolCall:
            EmptyView()
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
            if isUser { Spacer() }

            if isUser {
                userBubble(text: text, attachments: attachments)
            } else {
                chappieBubble(text: text, cost: cost, attachments: attachments)
            }

            if !isUser { Spacer() }
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            )
        )
        .id(msg.id)
    }

    // MARK: - Terminal Confirmation Bubble

    @ViewBuilder
    private func terminalConfirmationBubble(id: UUID, command: String, threadId: UUID) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("Terminal — confirmation required")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text(command)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Button {
                        viewModel.approveTerminalCommand(messageId: id, command: command)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)

                    Button {
                        viewModel.rejectTerminalCommand(messageId: id, command: command)
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
                .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
            )

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
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
    }

    // MARK: - Chappie Bubble

    @ViewBuilder
    private func chappieBubble(text: String, cost: Double?, attachments: [AttachedFile]) -> some View {
        HStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 6) {
                    // Output file attachments shown above the text — they're the main result.
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

            Spacer()
        }
    }
}

// MARK: - AttachmentListView

private struct AttachmentListView: View {

    let attachments: [AttachedFile]
    let isUser: Bool

    @State private var previewURL: URL? = nil

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(attachments) { file in
                AttachmentRowView(file: file, isUser: isUser) {
                    handleTap(file: file)
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func handleTap(file: AttachedFile) {
        // All files go through QuickLook — native preview + built-in Share button.
        // For AI-generated files with a permanent localURL, use it directly.
        // For user-attached files, write to temp first.
        if let localURL = file.localURL, FileManager.default.fileExists(atPath: localURL.path) {
            previewURL = localURL
        } else {
            previewURL = writeTempFile(file)
        }
    }

    private func writeTempFile(_ file: AttachedFile) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(file.filename)
        try? file.data.write(to: url)
        return url
    }
}

// MARK: - AttachmentRowView

private struct AttachmentRowView: View {

    let file: AttachedFile
    let isUser: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: file.mimeType.isImage ? "photo" : file.mimeType.systemIcon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)

                Text(file.filename)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

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
        .help("Preview \(file.filename)")
    }

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
    let sampleDocx = AttachedFile(filename: "plan.docx", mimeType: .docx, data: Data(count: 21300), localURL: URL(fileURLWithPath: "/tmp/plan.docx"))

    return ScrollView {
        VStack(spacing: 16) {
            MessageBubbleView(msg: .message(isUser: true, text: "Переведи этот документ на английский", attachments: [samplePDF]), availableWidth: 618)
            MessageBubbleView(msg: .message(isUser: false, text: "Готово! Вот переведённый документ:", cost: 12.5, attachments: [sampleDocx]), availableWidth: 618)
            MessageBubbleView(msg: .message(isUser: true, text: "Here's the screenshot", attachments: [sampleImage]), availableWidth: 618)
            MessageBubbleView(msg: .terminalConfirmation(command: "swift test --filter ToolExecutionServiceTests", threadId: UUID()), availableWidth: 618)
        }
        .padding()
    }
    .frame(width: 650, height: 600)
    .background(Color(NSColor.windowBackgroundColor))
}
