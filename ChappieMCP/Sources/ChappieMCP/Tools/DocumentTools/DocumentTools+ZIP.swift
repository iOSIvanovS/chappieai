// DocumentTools+ZIP.swift
// ChappieMCP
//
// WHY THIS FILE:
// Handles read/write for ZIP-based Office formats: docx, xlsx, pptx, odt.
// Strategy: unzip → expose primary XML entry → AI modifies → repack into valid archive.
// All other ZIP entries (styles, images, relationships) are preserved untouched.

import Foundation
import ZIPFoundation

extension DocumentTools {

    // MARK: - ZIP XML reading

    /// Reads one or more named entries from a ZIP archive and returns their XML content.
    func readZipXML(at path: String, entries: [String], format: String) -> ToolResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("read_document: file not found at '\(path)'")
        }

        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else {
            return .failure("read_document: cannot open '\(path)' as a ZIP archive. The file may be corrupted.")
        }

        var parts: [String] = []
        for entryName in entries {
            guard let entry = archive[entryName] else {
                // Some xlsx files have no sharedStrings.xml — skip gracefully.
                continue
            }
            var data = Data()
            do {
                _ = try archive.extract(entry, consumer: { chunk in data.append(chunk) })
            } catch {
                return .failure("read_document: failed to extract '\(entryName)': \(error.localizedDescription)")
            }
            guard let xml = String(data: data, encoding: .utf8) else {
                return .failure("read_document: '\(entryName)' is not valid UTF-8 text.")
            }
            let normalized = normalizeOfficeXML(xml, entryName: entryName)
            parts.append("<!-- Entry: \(entryName) -->\n\(normalized)")
        }

        if parts.isEmpty {
            return .failure("read_document: no readable XML entries found in \(format) file.")
        }

        let header = "<!-- \(format) document: \(URL(fileURLWithPath: path).lastPathComponent) -->\n"
        return .success(header + parts.joined(separator: "\n\n"))
    }

    /// Reads all slides/sheets matching a prefix pattern (e.g. "ppt/slides/slide").
    func readZipXMLPattern(at path: String, prefix: String, format: String) -> ToolResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("read_document: file not found at '\(path)'")
        }

        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else {
            return .failure("read_document: cannot open '\(path)' as a ZIP archive.")
        }

        var matchingEntries: [String] = []
        for entry in archive {
            if entry.path.hasPrefix(prefix) && entry.path.hasSuffix(".xml") {
                matchingEntries.append(entry.path)
            }
        }
        matchingEntries.sort()

        if matchingEntries.isEmpty {
            return .failure("read_document: no entries found with prefix '\(prefix)' in \(format) file.")
        }

        return readZipXML(at: path, entries: matchingEntries, format: format)
    }

    // MARK: - ZIP entry replacement

    /// Creates a copy of the ZIP with one entry replaced, saves to outputPath.
    /// Works on a temp copy when overwriting in-place to avoid corruption on failure.
    /// Returns structured JSON: {"status":"ok","saved_path":"...","filename":"...","entry":"..."}
    func replaceZipEntry(sourcePath: String, entryName: String, newContent: String, outputPath: String) -> ToolResult {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            return .failure("write_document: source file not found at '\(sourcePath)'")
        }

        guard let xmlData = newContent.data(using: .utf8) else {
            return .failure("write_document: XML content is not valid UTF-8.")
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL = URL(fileURLWithPath: outputPath)

        let workURL: URL
        let needsMove: Bool
        if sourceURL.path == outputURL.path {
            // Overwriting in-place — use a temp file to avoid corruption on failure.
            let tmpPath = NSTemporaryDirectory() + UUID().uuidString + "." + sourceURL.pathExtension
            workURL = URL(fileURLWithPath: tmpPath)
            needsMove = true
            do {
                try FileManager.default.copyItem(at: sourceURL, to: workURL)
            } catch {
                return .failure("write_document: failed to create temp copy: \(error.localizedDescription)")
            }
        } else {
            workURL = outputURL
            needsMove = false
            do {
                let parentDir = outputURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: workURL)
            } catch {
                return .failure("write_document: failed to prepare output file: \(error.localizedDescription)")
            }
        }

        guard let archive = try? Archive(url: workURL, accessMode: .update, pathEncoding: nil) else {
            try? FileManager.default.removeItem(at: workURL)
            return .failure("write_document: cannot open archive for update.")
        }

        do {
            if let existing = archive[entryName] {
                try archive.remove(existing)
            }
            try archive.addEntry(
                with: entryName,
                type: .file,
                uncompressedSize: Int64(xmlData.count),
                provider: { position, size in
                    xmlData.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        } catch {
            try? FileManager.default.removeItem(at: workURL)
            return .failure("write_document: failed to update ZIP entry '\(entryName)': \(error.localizedDescription)")
        }

        if needsMove {
            do {
                _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: workURL)
            } catch {
                try? FileManager.default.removeItem(at: workURL)
                return .failure("write_document: failed to replace original file: \(error.localizedDescription)")
            }
        }

        let filename = outputURL.lastPathComponent
        let json = "{\"status\":\"ok\",\"saved_path\":\"\(outputURL.path)\",\"filename\":\"\(filename)\",\"entry\":\"\(entryName)\"}"
        return .success(json)
    }
}
