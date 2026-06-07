// AttachmentViews.swift
// Chappie
//
// AttachmentChipView: single chip for a pending attachment (thumbnail or icon + remove button).
// AttachmentChipsRow: horizontal scrollable strip rendered above the text editor.

import SwiftUI

// MARK: - AttachmentChipView

/// A single chip showing an attached file — thumbnail for images, icon for others.
/// Has an ✕ button to remove it from the pending list.
struct AttachmentChipView: View {

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

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("input.remove_attachment")
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

// MARK: - AttachmentChipsRow

/// Horizontal scrollable row of attachment chips shown above the text editor.
/// Only rendered when attachments is non-empty.
struct AttachmentChipsRow: View {

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
