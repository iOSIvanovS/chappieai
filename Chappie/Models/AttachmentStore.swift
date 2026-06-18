// AttachmentStore.swift
// Chappie
//
// WHY THIS EXISTS:
// Single source of truth for all attachment I/O.
// Files are stored at: Application Support/Chappie/Attachments/{attachmentId}/{filename}
// Using attachmentId (not messageId) as the folder key allows resolve(uuid:) to find
// any file by UUID alone — which is what the AI tools fetch_attachment/send_attachment need.
//
// AttachmentStore is the only place that knows where files live on disk.
// Everything else works with UUID + metadata.

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

    // MARK: - Save

    /// Copies a file from its source URL into a permanent per-attachment folder.
    /// Folder: Attachments/{attachmentId}/{filename}
    /// Returns the permanent URL, or nil if the copy failed.
    func save(fileAt sourceURL: URL, forAttachmentId attachmentId: UUID) -> URL? {
        let folder = folderURL(for: attachmentId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(sourceURL.lastPathComponent)
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

    /// Writes raw Data to a permanent per-attachment folder with the given filename.
    /// Used by send_attachment when the AI delivers file content directly.
    /// Returns the permanent URL, or nil if the write failed.
    func save(data: Data, filename: String, forAttachmentId attachmentId: UUID) -> URL? {
        let folder = folderURL(for: attachmentId)
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

    // MARK: - Resolve

    /// Resolves a UUID to the file URL on disk.
    /// Looks for the first file inside Attachments/{uuid}/.
    /// Returns nil if the folder doesn't exist or is empty.
    func resolve(uuid: UUID) -> URL? {
        let folder = folderURL(for: uuid)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ), let file = contents.first else {
            print("[AttachmentStore] resolve(uuid:) — not found: \(uuid)")
            return nil
        }
        return file
    }

    // MARK: - Folder

    func folderURL(for attachmentId: UUID) -> URL {
        rootURL.appendingPathComponent(attachmentId.uuidString, isDirectory: true)
    }
}
