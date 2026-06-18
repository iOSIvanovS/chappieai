// MessageBubbleView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Renders individual chat message bubbles in the conversation scroll view.
//
// ATTACHMENTS STRATEGY:
// Each attachment is one row: icon + filename + file size.
// All files open via QuickLook on click — native preview + built-in Share button.
// File size is read from disk via localURL (no bytes stored in AttachedFile).
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
                    Text("terminal.confirmation_required")
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
                            .padding(.bottom, (cost ?? 0) > 0 ? 18 : 0)
                    }
                }

                if let cost = cost, cost > 0 {
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
        // localURL is always set — resolve through AttachmentStore if file exists.
        guard FileManager.default.fileExists(atPath: file.localURL.path) else {
            print("[MessageBubbleView] File not found at: \(file.localURL.path)")
            return
        }
        previewURL = file.localURL
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

                Text(fileSizeString(for: file.localURL))
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

    /// Reads file size from disk — no bytes stored in AttachedFile.
    private func fileSizeString(for url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}
