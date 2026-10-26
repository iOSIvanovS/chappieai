// DocumentTools+Excel.swift
// ChappieMCP
//
// WHY THIS FILE:
// An .xlsx keeps each sheet in its own ZIP entry. Reading only sheet1 hid every other sheet
// from the model. This lists all sheets (plus workbook.xml, so sheet names are visible and
// sharedStrings, which the cells reference) in natural order: sheet2 before sheet10.

import Foundation
import ZIPFoundation

extension DocumentTools {

    func readExcel(at path: String) -> ToolResult {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else {
            return .failure("read_document: cannot open '\(path)' as a ZIP archive. The file may be corrupted.")
        }
        let entries = Self.excelEntries(archivePaths: archive.map { $0.path })
        return readZipXML(at: path, entries: entries, format: "Excel (.xlsx)", mediaFolders: ["xl/media/"])
    }

    /// Orders the entries to read: workbook (sheet names), shared strings, then every worksheet.
    static func excelEntries(archivePaths: [String]) -> [String] {
        let sheets = archivePaths
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        // Absent parts are skipped by readZipXML, so a fixed head list is safe.
        return ["xl/workbook.xml", "xl/sharedStrings.xml"] + sheets
    }
}
