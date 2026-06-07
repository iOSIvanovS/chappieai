// DocumentTools.swift
// ChappieMCP
//
// WHY THIS FILE:
// Implements read_document and write_document tools for Office document formats.
// .docx, .xlsx, .pptx are ZIP archives containing XML files — we unzip, expose XML
// to the AI, receive modified XML back, and repack into a valid Office document.
//
// This mirrors the read_file / write_file pattern exactly:
//   read_document  →  read_file  (returns full content for AI to understand)
//   write_document →  write_file (AI provides new content, we persist it)
//
// SUPPORTED FORMATS:
//   .docx  — word/document.xml (main body)
//   .xlsx  — xl/sharedStrings.xml + xl/worksheets/sheet*.xml
//   .pptx  — ppt/slides/slide*.xml
//   .pdf   — read-only via pdftotext (system tool) or text extraction fallback
//   .rtf   — plain text extraction (RTF is text-based, we strip control words)
//   .odt   — content.xml (OpenDocument ZIP, same approach)
//   .csv   — plain text, no conversion needed
//
// OFFICE XML NORMALIZATION:
// Word splits runs aggressively for spell-check / track-changes metadata:
//   <w:r><w:t>Ива</w:t></w:r><w:r><w:t>нов</w:t></w:r>
// We merge adjacent <w:r> elements with identical rPr (run properties) before
// returning XML to the AI. This makes the document readable and editable.
//
// WRITE STRATEGY:
// We receive the full modified XML string for the primary XML entry.
// We open the original ZIP, replace only the primary entry, repack → output file.
// All other ZIP entries (styles, images, relationships) are preserved untouched.
// If output_path is provided — write there. Otherwise overwrite the original.
//
// WRITE RESPONSE FORMAT (structured JSON):
// write_document returns JSON so ViewModel can reliably detect the output file:
//   {"status":"ok","saved_path":"/absolute/path/plan.docx","filename":"plan.docx"}
// This is more robust than parsing a human-readable success string.
//
// ZIPFoundation is used for ZIP operations (SPM dependency, no system installs needed).

import Foundation
import ZIPFoundation

// MARK: - DocumentTools

final class DocumentTools: Sendable {

    private let projectPath: String

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - read_document

    /// Extracts the primary XML content from an Office document.
    /// Returns normalized XML ready for AI consumption.
    func readDocument(relativePath: String) -> ToolResult {
        let fullPath = resolvePath(relativePath)
        let ext = URL(fileURLWithPath: fullPath).pathExtension.lowercased()

        switch ext {
        case "docx":
            return readZipXML(at: fullPath, entries: ["word/document.xml"], format: "Word (.docx)")
        case "xlsx":
            return readZipXML(at: fullPath, entries: ["xl/sharedStrings.xml", "xl/worksheets/sheet1.xml"], format: "Excel (.xlsx)")
        case "pptx":
            return readZipXMLPattern(at: fullPath, prefix: "ppt/slides/slide", format: "PowerPoint (.pptx)")
        case "odt":
            return readZipXML(at: fullPath, entries: ["content.xml"], format: "OpenDocument Text (.odt)")
        case "rtf":
            return readRTF(at: fullPath)
        case "csv":
            return readPlainText(at: fullPath, format: "CSV")
        case "pdf":
            return readPDF(at: fullPath)
        default:
            return .failure("read_document: unsupported format '.\(ext)'. Supported: docx, xlsx, pptx, odt, rtf, csv, pdf.")
        }
    }

    // MARK: - write_document

    /// Replaces the primary XML entry in the Office document ZIP and saves the result.
    /// Returns structured JSON so the caller can detect the output file path.
    /// - Parameters:
    ///   - relativePath: path to the original document
    ///   - xmlContent: full modified XML string for the primary entry
    ///   - outputPath: optional output path; if nil, overwrites the original
    ///   - entryName: which ZIP entry to replace (e.g. "word/document.xml")
    func writeDocument(relativePath: String, xmlContent: String, outputPath: String?, entryName: String?) -> ToolResult {
        let fullPath = resolvePath(relativePath)
        let ext = URL(fileURLWithPath: fullPath).pathExtension.lowercased()

        let primaryEntry: String
        switch ext {
        case "docx":      primaryEntry = entryName ?? "word/document.xml"
        case "xlsx":      primaryEntry = entryName ?? "xl/worksheets/sheet1.xml"
        case "pptx":      primaryEntry = entryName ?? "ppt/slides/slide1.xml"
        case "odt":       primaryEntry = entryName ?? "content.xml"
        case "rtf", "csv":
            return writePlainText(content: xmlContent, originalPath: fullPath, outputPath: outputPath.map { resolvePath($0) })
        default:
            return .failure("write_document: unsupported format '.\(ext)'. Supported: docx, xlsx, pptx, odt, rtf, csv.")
        }

        let destination = outputPath.map { resolvePath($0) } ?? fullPath
        return replaceZipEntry(sourcePath: fullPath, entryName: primaryEntry, newContent: xmlContent, outputPath: destination)
    }

    // MARK: - ZIP XML reading

    /// Reads one or more named entries from a ZIP archive and returns their XML content.
    private func readZipXML(at path: String, entries: [String], format: String) -> ToolResult {
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
    private func readZipXMLPattern(at path: String, prefix: String, format: String) -> ToolResult {
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
    /// Returns structured JSON on success: {"status":"ok","saved_path":"...","filename":"..."}
    private func replaceZipEntry(sourcePath: String, entryName: String, newContent: String, outputPath: String) -> ToolResult {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            return .failure("write_document: source file not found at '\(sourcePath)'")
        }

        guard let xmlData = newContent.data(using: .utf8) else {
            return .failure("write_document: XML content is not valid UTF-8.")
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL = URL(fileURLWithPath: outputPath)

        // If overwriting in-place, work on a temp copy to avoid corruption on failure.
        let workURL: URL
        let needsMove: Bool
        if sourceURL.path == outputURL.path {
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

        // Return structured JSON so ViewModel can detect and present the output file.
        let filename = outputURL.lastPathComponent
        let json = "{\"status\":\"ok\",\"saved_path\":\"\(outputURL.path)\",\"filename\":\"\(filename)\",\"entry\":\"\(entryName)\"}"
        return .success(json)
    }

    // MARK: - Plain text formats

    private func readPlainText(at path: String, format: String) -> ToolResult {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            guard let content = try? String(contentsOfFile: path, encoding: .isoLatin1) else {
                return .failure("read_document: cannot read \(format) file at '\(path)'.")
            }
            return .success(content)
        }
        return .success(content)
    }

    /// Returns structured JSON on success (same format as replaceZipEntry).
    private func writePlainText(content: String, originalPath: String, outputPath: String?) -> ToolResult {
        let target = outputPath ?? originalPath
        let targetURL = URL(fileURLWithPath: target)
        do {
            try content.write(toFile: target, atomically: true, encoding: .utf8)
            let filename = targetURL.lastPathComponent
            let json = "{\"status\":\"ok\",\"saved_path\":\"\(target)\",\"filename\":\"\(filename)\",\"entry\":\"\"}"
            return .success(json)
        } catch {
            return .failure("write_document: failed to write file: \(error.localizedDescription)")
        }
    }

    // MARK: - PDF (read-only)

    private func readPDF(at path: String) -> ToolResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("read_document: file not found at '\(path)'")
        }

        let pdftotextPath = "/opt/homebrew/bin/pdftotext"
        if FileManager.default.fileExists(atPath: pdftotextPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pdftotextPath)
            process.arguments = [path, "-"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    return .success("<!-- PDF document (text extraction): \(URL(fileURLWithPath: path).lastPathComponent) -->\n\(text)")
                }
            } catch { /* fall through to raw scan */ }
        }

        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure("read_document: cannot read PDF file.")
        }
        let text = extractTextFromPDFData(data)
        if text.isEmpty {
            return .failure("read_document: PDF text extraction failed. Install pdftotext (brew install poppler) for better results.")
        }
        return .success("<!-- PDF document (raw extraction): \(URL(fileURLWithPath: path).lastPathComponent) -->\n\(text)")
    }

    private func extractTextFromPDFData(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .isoLatin1) else { return "" }
        var result: [String] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "(" {
                let start = raw.index(after: i)
                var depth = 1
                var j = start
                while j < raw.endIndex && depth > 0 {
                    if raw[j] == "(" { depth += 1 }
                    else if raw[j] == ")" { depth -= 1 }
                    if depth > 0 { j = raw.index(after: j) }
                }
                if depth == 0 {
                    let token = String(raw[start..<j])
                    let cleaned = token.filter { $0.isLetter || $0.isNumber || $0.isWhitespace || ".,;:!?-–—\"'()".contains($0) }
                    if cleaned.count > 3 { result.append(cleaned) }
                    i = raw.index(after: j)
                    continue
                }
            }
            i = raw.index(after: i)
        }
        return result.joined(separator: " ")
    }

    // MARK: - RTF

    private func readRTF(at path: String) -> ToolResult {
        guard let content = try? String(contentsOfFile: path, encoding: .isoLatin1) else {
            return .failure("read_document: cannot read RTF file at '\(path)'.")
        }
        let plain = stripRTFControlWords(content)
        return .success("<!-- RTF document: \(URL(fileURLWithPath: path).lastPathComponent) -->\n\(plain)")
    }

    private func stripRTFControlWords(_ rtf: String) -> String {
        var result = ""
        var i = rtf.startIndex
        while i < rtf.endIndex {
            let c = rtf[i]
            if c == "\\" {
                let next = rtf.index(after: i)
                guard next < rtf.endIndex else { break }
                let n = rtf[next]
                if n == "\\" || n == "{" || n == "}" {
                    result.append(n)
                    i = rtf.index(after: next)
                } else if n == "'" {
                    let h1 = rtf.index(after: next)
                    let h2 = h1 < rtf.endIndex ? rtf.index(after: h1) : h1
                    if h2 < rtf.endIndex {
                        let hex = String(rtf[h1...h2])
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                            result.append(Character(scalar))
                        }
                        i = rtf.index(after: h2)
                    } else {
                        i = rtf.index(after: next)
                    }
                } else {
                    i = rtf.index(after: next)
                    while i < rtf.endIndex && (rtf[i].isLetter || rtf[i].isNumber || rtf[i] == "-") {
                        i = rtf.index(after: i)
                    }
                    if i < rtf.endIndex && rtf[i] == " " {
                        i = rtf.index(after: i)
                    }
                }
            } else if c == "{" || c == "}" {
                i = rtf.index(after: i)
            } else {
                result.append(c)
                i = rtf.index(after: i)
            }
        }
        return result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Office XML normalization

    /// Normalizes Office XML to make it readable and editable by AI.
    /// Removes revision noise (rsid* attrs, proofErr tags) without touching content.
    private func normalizeOfficeXML(_ xml: String, entryName: String) -> String {
        guard entryName.hasSuffix(".xml") else { return xml }
        guard entryName.hasPrefix("word/") else { return xml }
        return mergeAdjacentWordRuns(xml)
    }

    private func mergeAdjacentWordRuns(_ xml: String) -> String {
        var result = xml
        result = removeXMLAttributes(result, matching: ["w:rsidR", "w:rsidRPr", "w:rsidDel", "w:rsidRDefault"])
        result = removeXMLElements(result, tags: ["w:proofErr", "w:bookmarkStart", "w:bookmarkEnd"])
        return result
    }

    private func removeXMLAttributes(_ xml: String, matching attrNames: [String]) -> String {
        var result = xml
        for attr in attrNames {
            var output = ""
            var i = result.startIndex
            while i < result.endIndex {
                if result[i...].hasPrefix(attr) {
                    let afterAttr = result.index(i, offsetBy: attr.count, limitedBy: result.endIndex) ?? result.endIndex
                    var j = afterAttr
                    while j < result.endIndex && result[j] == " " { j = result.index(after: j) }
                    if j < result.endIndex && result[j] == "=" {
                        j = result.index(after: j)
                        if j < result.endIndex && result[j] == "\"" {
                            j = result.index(after: j)
                            while j < result.endIndex && result[j] != "\"" { j = result.index(after: j) }
                            if j < result.endIndex { j = result.index(after: j) }
                            if let prev = output.indices.last, output[prev] == " " {
                                output.removeLast()
                            }
                            i = j
                            continue
                        }
                    }
                }
                output.append(result[i])
                i = result.index(after: i)
            }
            result = output
        }
        return result
    }

    private func removeXMLElements(_ xml: String, tags: [String]) -> String {
        var result = xml
        for tag in tags {
            var output = ""
            var i = result.startIndex
            while i < result.endIndex {
                if result[i] == "<" {
                    let afterBracket = result.index(after: i)
                    if result[afterBracket...].hasPrefix(tag) {
                        var j = afterBracket
                        while j < result.endIndex && result[j] != ">" { j = result.index(after: j) }
                        if j < result.endIndex {
                            j = result.index(after: j)
                            i = j
                            continue
                        }
                    }
                }
                output.append(result[i])
                i = result.index(after: i)
            }
            result = output
        }
        return result
    }

    // MARK: - Path helpers

    private func resolvePath(_ relativePath: String) -> String {
        if relativePath.hasPrefix("/") { return relativePath }
        return projectPath + "/" + relativePath
    }
}
