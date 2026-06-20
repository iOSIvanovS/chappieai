// LocalizationTools.swift
//
// WHY: MCP tools for working with .xcstrings localization files in Xcode projects.
// These tools serve as a navigator for Chappie AI — so the AI doesn't have to
// manually scan hundreds of files to find what needs translation.
//
// XCSTRINGS FORMAT:
// .xcstrings is a JSON file. Structure:
// {
//   "sourceLanguage": "en",
//   "strings": {
//     "key": {
//       "comment": "optional comment",
//       "localizations": {
//         "en": { "stringUnit": { "state": "translated", "value": "Hello" } },
//         "ru": { "stringUnit": { "state": "translated", "value": "Привет" } }
//       }
//     }
//   },
//   "version": "1.0"
// }

import Foundation

// MARK: - LocalizationTools

/// Entry point for all localization MCP tools.
final class LocalizationTools: Sendable {
    let projectPath: String

    /// Path to batch state file in /tmp — survives between tool calls.
    let batchStatePath = "/tmp/chappie_loc_batch_state.json"

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - loc_info

    /// Returns a map of all .xcstrings files in the project with coverage stats.
    func info() -> ToolResult {
        let files = findXCStringsFiles()

        if files.isEmpty {
            return .success("""
            No .xcstrings files found in project.
            Use loc_create to create a new localization file.
            Tip: standard location is <TargetName>/Localizable.xcstrings
            """)
        }

        var report = "📦 Localization files found: \(files.count)\n\n"

        for filePath in files {
            let relativePath = filePath.replacingOccurrences(of: projectPath + "/", with: "")
            report += "📄 \(relativePath)\n"

            guard let xcstrings = loadXCStrings(at: filePath) else {
                report += "   ⚠️ Failed to parse file\n\n"
                continue
            }

            let sourceLanguage = xcstrings.sourceLanguage
            let allKeys = xcstrings.strings.keys.sorted()
            let totalKeys = allKeys.count

            var allLanguages = Set<String>()
            for (_, entry) in xcstrings.strings {
                for lang in (entry.localizations ?? [:]).keys {
                    allLanguages.insert(lang)
                }
            }
            allLanguages.insert(sourceLanguage)
            let languages = allLanguages.sorted()

            report += "   Source language: \(sourceLanguage)\n"
            report += "   Total keys: \(totalKeys)\n"
            report += "   Languages: \(languages.joined(separator: ", "))\n"

            if totalKeys > 0 {
                report += "   Coverage:\n"
                for lang in languages {
                    let translated = allKeys.filter { key in
                        guard let entry = xcstrings.strings[key],
                              let locs = entry.localizations,
                              let loc = locs[lang],
                              let unit = loc.stringUnit else { return false }
                        return unit.state == "translated" && !unit.value.isEmpty
                    }.count
                    let percent = Int(Double(translated) / Double(totalKeys) * 100)
                    let bar = String(repeating: "█", count: percent / 10) +
                              String(repeating: "░", count: 10 - percent / 10)
                    report += "     \(lang.padding(toLength: 6, withPad: " ", startingAt: 0)) \(bar) \(percent)% (\(translated)/\(totalKeys))\n"
                }
            }
            report += "\n"
        }

        return .success(report)
    }

    // MARK: - loc_create

    /// Creates a new .xcstrings file at the given path relative to project root.
    func create(relativePath: String, sourceLanguage: String) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        if FileManager.default.fileExists(atPath: fullPath) {
            return .failure("File already exists: \(relativePath)\nUse loc_info to see existing files.")
        }

        let dir = URL(fileURLWithPath: fullPath).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failure("Failed to create directory \(dir): \(error.localizedDescription)")
        }

        let xcstrings = XCStringsFile(sourceLanguage: sourceLanguage, strings: [:], version: "1.0")

        guard let data = try? JSONEncoder.xcstrings.encode(xcstrings),
              let pretty = prettyPrint(data) else {
            return .failure("Failed to encode xcstrings file")
        }

        do {
            try pretty.write(toFile: fullPath, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Failed to write file: \(error.localizedDescription)")
        }

        return .success("""
        ✅ Created: \(relativePath)
        Source language: \(sourceLanguage)

        Next steps:
        1. Add the file to your Xcode target (drag into Xcode project navigator)
        2. Use loc_add_language to add target languages
        3. Use loc_submit_batch to add translations
        """)
    }

    // MARK: - loc_rename

    /// Renames (moves) a .xcstrings file.
    func rename(fromRelativePath: String, toRelativePath: String) -> ToolResult {
        let fromPath = projectPath + "/" + fromRelativePath
        let toPath = projectPath + "/" + toRelativePath

        guard FileManager.default.fileExists(atPath: fromPath) else {
            return .failure("File not found: \(fromRelativePath)")
        }

        if FileManager.default.fileExists(atPath: toPath) {
            return .failure("Destination already exists: \(toRelativePath)")
        }

        let toDir = URL(fileURLWithPath: toPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: toDir, withIntermediateDirectories: true)

        do {
            try FileManager.default.moveItem(atPath: fromPath, toPath: toPath)
        } catch {
            return .failure("Failed to rename: \(error.localizedDescription)")
        }

        return .success("✅ Renamed: \(fromRelativePath) → \(toRelativePath)\n⚠️ Remember to update the file reference in Xcode project navigator.")
    }

    // MARK: - loc_delete

    /// Deletes a .xcstrings file.
    func delete(relativePath: String) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        guard FileManager.default.fileExists(atPath: fullPath) else {
            return .failure("File not found: \(relativePath)")
        }

        do {
            try FileManager.default.removeItem(atPath: fullPath)
        } catch {
            return .failure("Failed to delete: \(error.localizedDescription)")
        }

        return .success("✅ Deleted: \(relativePath)\n⚠️ Remember to remove the file reference from Xcode project navigator.")
    }
}
