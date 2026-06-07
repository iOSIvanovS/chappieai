// AttachmentStore.swift
// Chappie
//
// WHY THIS EXISTS:
// Office documents (and any non-image attachments) need to survive beyond the send() call.
// Previously files were written to /tmp and deleted immediately after extraction — making
// repeat access (e.g. re-reading, writing back) impossible.
//
// AttachmentStore copies incoming files to:
//   Application Support/Chappie/Attachments/{messageID}/{filename}
// and saves outgoing AI-generated files to the same structure under the AI message ID.
// Files live as long as the app data — no stale references.
//
// WHY NOT STORE DATA IN AttachedFile:
// Storing raw bytes inline works for images (small, no re-use needed).
// For Office docs it wastes memory and prevents write_document from knowing where to save.
// localURL is the source of truth; data field is kept for backward compat with images.

import Foundation

final class AttachmentStore {

    // MARK: - Singleton

    static let shared = AttachmentStore()
    private init() {}

    // MARK: - Root Directory

    /// ~/Library/Application Support/Chappie/Attachments/
    private var rootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Chappie/Attachments", isDirectory: true)
    }

    // MARK: - Save Incoming Attachment

    /// Copies a file from its source URL into a permanent per-message folder.
    /// Returns the permanent URL, or nil if the copy failed.
    func save(fileAt sourceURL: URL, forMessageId messageId: UUID) -> URL? {
        let folder = folderURL(for: messageId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(sourceURL.lastPathComponent)
            // Overwrite if re-saving the same file (idempotent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return dest
        } catch {
            print("[AttachmentStore] Failed to save \(sourceURL.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Writes raw Data to a permanent per-message folder with the given filename.
    /// Used when the attachment arrives as Data (from AttachedFile.data) rather than a URL.
    func save(data: Data, filename: String, forMessageId messageId: UUID) -> URL? {
        let folder = folderURL(for: messageId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(filename)
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            print("[AttachmentStore] Failed to write \(filename): \(error)")
            return nil
        }
    }

    // MARK: - Reserve Output URL

    /// Returns a URL where an AI-generated file should be saved for a given message.
    /// Creates the folder. The caller (write_document) writes the file to this URL.
    func outputURL(filename: String, forMessageId messageId: UUID) -> URL {
        let folder = folderURL(for: messageId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(filename)
    }

    // MARK: - Folder

    func folderURL(for messageId: UUID) -> URL {
        rootURL.appendingPathComponent(messageId.uuidString, isDirectory: true)
    }
}
