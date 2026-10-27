// DocumentTools+Text.swift
// ChappieMCP
//
// WHY THIS FILE:
// Handles plain-text formats: RTF and CSV.
// RTF strips control words to expose readable plain text.
// PDF lives in DocumentTools+PDF.swift (its own tools).

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
