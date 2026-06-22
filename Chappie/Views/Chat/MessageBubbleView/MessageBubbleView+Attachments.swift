// MessageBubbleView+Attachments.swift
// Chappie
//
// WHY: Attachment rendering isolated from bubble layout.
// AttachmentListView — QuickLook container.
// AttachmentRowView — single file chip (icon + name + size).

import SwiftUI
import QuickLook


// MARK: - AttachmentListView

struct AttachmentListView: View {

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

struct AttachmentRowView: View {

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
