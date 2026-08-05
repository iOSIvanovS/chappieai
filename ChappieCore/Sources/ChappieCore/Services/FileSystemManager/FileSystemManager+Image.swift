// FileSystemManager+Image.swift
// ChappieCore
//
// Reads raw image bytes for view_image tool — separate from readFile() because
// images must never be decoded as UTF-8 text (readFile would corrupt binary data).

import Foundation

extension FileSystemManager {

    /// Max image size accepted by view_image — keeps request payloads reasonable.
    static let maxImageBytes = 5 * 1024 * 1024

    /// Reads an image file as raw bytes + its MIME type, resolved by extension.
    /// Same path-traversal guard as readFile() — routes through validateAndResolvePath().
    public func readImageData(at path: String, projectName: String? = nil) throws -> (data: Data, mimeType: String) {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)

        let ext = safeURL.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png":         mimeType = "image/png"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "gif":         mimeType = "image/gif"
        case "webp":        mimeType = "image/webp"
        default:
            throw ChappieError.fileSystemError(
                "Unsupported image extension '.\(ext)' for '\(path)'. Supported: png, jpg, jpeg, gif, webp."
            )
        }

        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw ChappieError.fileSystemError("Image not found: '\(path)'")
        }

        let data: Data
        do {
            data = try Data(contentsOf: safeURL)
        } catch {
            throw ChappieError.fileSystemError("Failed to read image '\(path)': \(error.localizedDescription)")
        }

        guard data.count <= Self.maxImageBytes else {
            throw ChappieError.fileSystemError(
                "Image '\(path)' is too large (\(data.count / 1024)KB). Max allowed: \(Self.maxImageBytes / 1024 / 1024)MB."
            )
        }

        return (data, mimeType)
    }
}
