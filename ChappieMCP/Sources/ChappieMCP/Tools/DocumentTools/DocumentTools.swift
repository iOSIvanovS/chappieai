// DocumentTools.swift
// ChappieMCP
//
// WHY THIS FILE:
// Routes read_document and write_document tool calls.
// Actual format handling is split into focused extensions:
//   +ZIP    — read/write ZIP-based Office formats (docx, xlsx, pptx, odt)
//   +Text   — plain text formats (rtf, csv, pdf)
//   +XMLNormalization — Office XML cleanup before returning to AI

import Foundation
import ZIPFoundation

// MARK: - DocumentTools

final class DocumentTools: Sendable {

    let projectPath: String
    // WHY: supports multi-project threads — resolves path by project name, same pattern as GitTools/BuildTools.
    let projectPathMap: [String: String]

    init(projectPath: String, projectPathMap: [String: String] = [:]) {
        self.projectPath = projectPath
        self.projectPathMap = projectPathMap
    }

    // MARK: - read_document

    /// Routes to the correct reader based on file extension.
    func readDocument(relativePath: String, projectName: String? = nil) -> ToolResult {
        let fullPath = resolvePath(relativePath, projectName: projectName)
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

    /// Routes to ZIP patcher or plain-text writer based on file extension.
    /// Returns structured JSON: {"status":"ok","saved_path":"...","filename":"..."}
    func writeDocument(relativePath: String, xmlContent: String, outputPath: String?, entryName: String?, projectName: String? = nil) -> ToolResult {
        let fullPath = resolvePath(relativePath, projectName: projectName)
        let ext = URL(fileURLWithPath: fullPath).pathExtension.lowercased()

        let primaryEntry: String
        switch ext {
        case "docx":      primaryEntry = entryName ?? "word/document.xml"
        case "xlsx":      primaryEntry = entryName ?? "xl/worksheets/sheet1.xml"
        case "pptx":      primaryEntry = entryName ?? "ppt/slides/slide1.xml"
        case "odt":       primaryEntry = entryName ?? "content.xml"
        case "rtf", "csv":
            return writePlainText(content: xmlContent, originalPath: fullPath, outputPath: outputPath.map { resolvePath($0, projectName: projectName) })
        default:
            return .failure("write_document: unsupported format '.\(ext)'. Supported: docx, xlsx, pptx, odt, rtf, csv.")
        }

        let destination = outputPath.map { resolvePath($0, projectName: projectName) } ?? fullPath
        return replaceZipEntry(sourcePath: fullPath, entryName: primaryEntry, newContent: xmlContent, outputPath: destination)
    }

    // MARK: - Path helpers

    func resolvePath(_ relativePath: String, projectName: String? = nil) -> String {
        if relativePath.hasPrefix("/") { return relativePath }
        // WHY: when a named project is specified, resolve against its root — not the default project.
        let base: String
        if let name = projectName, let mapped = projectPathMap[name] {
            base = mapped
            // WHY: list_files returns "ProjectName/file.docx" — strip the prefix to avoid double-nesting.
            let prefix = name + "/"
            let stripped = relativePath.hasPrefix(prefix) ? String(relativePath.dropFirst(prefix.count)) : relativePath
            return base + "/" + stripped
        } else {
            base = projectPath
        }
        return base + "/" + relativePath
    }
}
