// DocumentTools+Text.swift
// ChappieMCP
//
// WHY THIS FILE:
// Handles plain-text and binary-text formats: RTF, CSV, PDF.
// PDF is read-only — extracted via pdftotext (Homebrew) or raw byte scan fallback.
// RTF strips control words to expose readable plain text.

import Foundation

extension DocumentTools {

    // MARK: - Plain text (CSV, RTF write)

    func readPlainText(at path: String, format: String) -> ToolResult {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            guard let content = try? String(contentsOfFile: path, encoding: .isoLatin1) else {
                return .failure("read_document: cannot read \(format) file at '\(path)'.")
            }
            return .success(content)
        }
        return .success(content)
    }

    /// Returns structured JSON on success (same format as replaceZipEntry).
    func writePlainText(content: String, originalPath: String, outputPath: String?) -> ToolResult {
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

    func readPDF(at path: String) async -> ToolResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("read_document: file not found at '\(path)'")
        }

        // Prefer pdftotext (brew install poppler) for high-quality extraction. Large PDFs can take
        // a while, so it runs through the shared runner and stops when the app cancels the call.
        let pdftotextPath = "/opt/homebrew/bin/pdftotext"
        if FileManager.default.fileExists(atPath: pdftotextPath) {
            let run = await ProcessRunner.run(
                executable: pdftotextPath,
                args: [path, "-"],
                environment: ["HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
            )
            if run.stopReason == .cancelled {
                return .failure("🛑 read_document was cancelled.")
            }
            let text = run.stdoutText
            if run.launchError == nil, !text.isEmpty {
                return .success("<!-- PDF document (text extraction): \(URL(fileURLWithPath: path).lastPathComponent) -->\n\(text)")
            }
            // Otherwise fall through to the raw scan.
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

    /// Fallback PDF text extraction — scans for parenthesised string objects in raw PDF bytes.
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

    func readRTF(at path: String) -> ToolResult {
        guard let content = try? String(contentsOfFile: path, encoding: .isoLatin1) else {
            return .failure("read_document: cannot read RTF file at '\(path)'.")
        }
        let plain = stripRTFControlWords(content)
        return .success("<!-- RTF document: \(URL(fileURLWithPath: path).lastPathComponent) -->\n\(plain)")
    }

    /// Strips RTF control words, leaving readable plain text with decoded special chars.
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
}
