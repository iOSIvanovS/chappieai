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
//
// WHY nonisolated methods:
// AttachmentStore only calls FileManager — no UI, no @MainActor state.
// All methods are nonisolated so Sendable closures in ToolExecutionService
// (a Swift actor) can call them directly without hopping to the main actor.
// FileManager file ops are thread-safe for concurrent reads/writes to different paths.

import Foundation

final class AttachmentStore: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = AttachmentStore()

    nonisolated private init() {}

    // MARK: - Root Directory

    /// ~/Library/Application Support/Chappie/Attachments/
    private nonisolated var rootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Chappie/Attachments", isDirectory: true)
    }

    // MARK: - Save

    /// Copies a file from its source URL into a permanent per-attachment folder.
    /// Folder: Attachments/{attachmentId}/{filename}
    /// Returns the permanent URL, or nil if the copy failed.
    nonisolated func save(fileAt sourceURL: URL, forAttachmentId attachmentId: UUID) -> URL? {
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
    nonisolated func save(data: Data, filename: String, forAttachmentId attachmentId: UUID) -> URL? {
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

    /// Reserves a URL for a file that will be written externally (e.g. by MCP write_document).
    /// Creates the folder. The caller writes the file to the returned URL.
    nonisolated func reserveURL(filename: String, forAttachmentId attachmentId: UUID) -> URL {
        let folder = folderURL(for: attachmentId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(filename)
    }

    // MARK: - Resolve

    /// Resolves a UUID to the file URL on disk.
    /// Looks for the first file inside Attachments/{uuid}/.
    /// Returns nil if the folder doesn't exist or is empty.
    nonisolated func resolve(uuid: UUID) -> URL? {
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

    // MARK: - Downscaled image cache

    /// Where the downscaled JPEG of an image attachment lives. Deliberately NOT inside the attachment's
    /// own folder: resolve(uuid:) returns the first file of that folder and must keep returning the original.
    nonisolated func downscaledImageURL(for attachmentId: UUID) -> URL {
        rootURL.deletingLastPathComponent()
            .appendingPathComponent("ImageCache", isDirectory: true)
            .appendingPathComponent("\(attachmentId.uuidString).jpg")
    }

    // MARK: - Folder

    nonisolated func folderURL(for attachmentId: UUID) -> URL {
        rootURL.appendingPathComponent(attachmentId.uuidString, isDirectory: true)
    }
}
