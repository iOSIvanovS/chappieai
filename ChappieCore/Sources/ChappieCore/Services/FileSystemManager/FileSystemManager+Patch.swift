// FileSystemManager+Patch.swift
// ChappieCore
//
// Surgical file edits (patch_file) and file metadata (get_file_info).
// patch_file enforces exactlyOne policy — 0 or 2+ matches are rejected.

import Foundation

extension FileSystemManager {

    // MARK: - File info

    /// Returns metadata for a file: size, line count, last modified date.
    /// WHY: avoids reading the entire file just to know its size or line count.
    public func getFileInfo(at path: String, projectName: String? = nil) throws -> String {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)

        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw ChappieError.fileSystemError("File not found: '\(path)'")
        }

        let attrs = try fileManager.attributesOfItem(atPath: safeURL.path)
        let size = attrs[.size] as? Int ?? 0
        let modDate = attrs[.modificationDate] as? Date

        // Count lines without loading the full content into a String
        let lineCount: Int
        if let data = try? Data(contentsOf: safeURL) {
            lineCount = data.filter { $0 == UInt8(ascii: "\n") }.count + 1
        } else {
            lineCount = 0
        }

        let formatter = ISO8601DateFormatter()
        let modString = modDate.map { formatter.string(from: $0) } ?? "unknown"

        let sizeFormatted: String
        if size < 1024 {
            sizeFormatted = "\(size) B"
        } else if size < 1024 * 1024 {
            sizeFormatted = String(format: "%.1f KB", Double(size) / 1024)
        } else {
            sizeFormatted = String(format: "%.1f MB", Double(size) / (1024 * 1024))
        }

        return """
        path: \(path)
        size: \(sizeFormatted) (\(size) bytes)
        lines: \(lineCount)
        modified: \(modString)
        """
    }

    // MARK: - Patch file

    /// Replaces an exact block of text in a file without reading the whole file into AI context.
    /// WHY: surgical edits after search_in_file cost ~200 tokens vs ~6000 for read→write.
    ///
    /// Safety policy (exactlyOne by default):
    ///   - 0 matches → error: find block not found, nothing changed.
    ///   - 1 match   → replace, write atomically.
    ///   - 2+ matches → error: ambiguous, nothing changed. Use a longer find block.
    public func patchFile(
        at path: String,
        find: String,
        replace: String,
        projectName: String? = nil
    ) throws -> String {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)

        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw ChappieError.fileSystemError("File not found: '\(path)'")
        }

        let content: String
        do {
            content = try String(contentsOf: safeURL, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError("Failed to read '\(path)': \(error.localizedDescription)")
        }

        // Count occurrences to enforce exactlyOne policy
        var count = 0
        var searchRange = content.startIndex..<content.endIndex
        while let range = content.range(of: find, options: .literal, range: searchRange) {
            count += 1
            if count > 1 { break } // no need to count further
            searchRange = range.upperBound..<content.endIndex
        }

        switch count {
        case 0:
            return "Error: patch_file — find block not found in '\(path)'. Nothing changed.\nMake sure the find block matches the file exactly (including indentation and whitespace)."
        case 1:
            let patched = content.replacingOccurrences(of: find, with: replace, options: .literal)
            do {
                // atomically: true — write is all-or-nothing, prevents partial corruption on crash
                try patched.write(to: safeURL, atomically: true, encoding: .utf8)
            } catch {
                throw ChappieError.fileSystemError("Failed to write patch to '\(path)': \(error.localizedDescription)")
            }
            return "Success: patch applied to '\(path)'."
        default:
            return "Error: patch_file — find block matches \(count) locations in '\(path)'. Nothing changed.\nUse a longer, more unique find block (at least 3–5 lines) to make the match unambiguous."
        }
    }
}
