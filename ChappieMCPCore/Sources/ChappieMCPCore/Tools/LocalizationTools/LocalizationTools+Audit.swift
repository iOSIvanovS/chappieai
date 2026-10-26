// LocalizationTools+Audit.swift
//
// WHY: Dead key detection — finds keys in .xcstrings not referenced in any .swift file.

import Foundation

extension LocalizationTools {

    // MARK: - loc_dead_keys

    /// Finds keys in xcstrings that are not used anywhere in .swift files.
    func deadKeys(relativePath: String) -> ToolResult {
        let fullPath: String
        do { fullPath = try resolveFullPath(relativePath) } catch { return .failure("\(error)") }

        guard let xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        let keys = Array(xcstrings.strings.keys)
        if keys.isEmpty {
            return .success("No keys found in \(relativePath).")
        }

        // Scan only the project that owns the file: another project's code says nothing about its keys.
        let scanRoots = root(containing: fullPath).map { [$0] } ?? usableRoots()
        let swiftFiles = findSwiftFiles(in: scanRoots)
        var allSourceCode = ""
        for swiftFile in swiftFiles {
            if let content = try? String(contentsOfFile: swiftFile, encoding: .utf8) {
                allSourceCode += content + "\n"
            }
        }

        var deadKeys: [String] = []
        var usedKeys: [String] = []

        for key in keys.sorted() {
            if allSourceCode.contains("\"\(key)\"") {
                usedKeys.append(key)
            } else {
                deadKeys.append(key)
            }
        }

        var report = "🔍 Dead key analysis: \(relativePath)\n"
        report += "   Scanned \(swiftFiles.count) Swift files\n"
        report += "   Total keys: \(keys.count)\n"
        report += "   Used: \(usedKeys.count)\n"
        report += "   Dead (not found in code): \(deadKeys.count)\n\n"

        if deadKeys.isEmpty {
            report += "✅ All keys are used in code!"
        } else {
            report += "⚠️ Dead keys:\n"
            for key in deadKeys {
                report += "   • \"\(key)\"\n"
            }
            report += "\nThese keys can be safely removed with loc_remove_key."
        }

        return .success(report)
    }
}
