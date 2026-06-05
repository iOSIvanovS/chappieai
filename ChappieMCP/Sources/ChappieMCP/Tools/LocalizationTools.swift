// LocalizationTools.swift
//
// WHY THIS FILE:
// MCP tools for working with .xcstrings localization files in Xcode projects.
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
//
// BATCH STATE:
// Stored in /tmp/chappie_loc_batch_state.json to survive between tool calls.
// Tracks which keys have already been handed out for translation.
//
// ENGLISH AS SOURCE LANGUAGE:
// English is always the source language. All keys must have an English value.
// Other languages are targets. Batch size = 100 / number of target languages.
//
// STATE RULE:
// Always set state: "translated" — never leave empty or "needs_review".
// Yellow warnings in Xcode appear when state is missing or "needs_review".

import Foundation

// MARK: - LocalizationTools

/// Tools for managing .xcstrings localization files.
final class LocalizationTools: Sendable {
    private let projectPath: String

    /// Path to batch state file in /tmp — survives between tool calls.
    private let batchStatePath = "/tmp/chappie_loc_batch_state.json"

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

            // Collect all languages present in any key
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

        // Check if already exists
        if FileManager.default.fileExists(atPath: fullPath) {
            return .failure("File already exists: \(relativePath)\nUse loc_info to see existing files.")
        }

        // Build directory if needed
        let dir = URL(fileURLWithPath: fullPath).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failure("Failed to create directory \(dir): \(error.localizedDescription)")
        }

        let xcstrings = XCStringsFile(
            sourceLanguage: sourceLanguage,
            strings: [:],
            version: "1.0"
        )

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

    // MARK: - loc_add_language

    /// Adds a target language to a .xcstrings file (or all files if path is empty).
    func addLanguage(language: String, relativePath: String?) -> ToolResult {
        let files: [String]
        if let relativePath, !relativePath.isEmpty {
            files = [projectPath + "/" + relativePath]
        } else {
            files = findXCStringsFiles()
        }

        if files.isEmpty {
            return .failure("No .xcstrings files found. Use loc_create first.")
        }

        var results: [String] = []

        for filePath in files {
            let rel = filePath.replacingOccurrences(of: projectPath + "/", with: "")

            guard var xcstrings = loadXCStrings(at: filePath) else {
                results.append("⚠️ \(rel): failed to parse")
                continue
            }

            // Add language entry to all existing keys (empty = will need translation)
            var modified = 0
            for key in xcstrings.strings.keys {
                if xcstrings.strings[key]?.localizations == nil {
                    xcstrings.strings[key]?.localizations = [:]
                }
                if xcstrings.strings[key]?.localizations?[language] == nil {
                    xcstrings.strings[key]?.localizations?[language] = XCLocalization(
                        stringUnit: XCStringUnit(state: "needs_review", value: "")
                    )
                    modified += 1
                }
            }

            if saveXCStrings(xcstrings, to: filePath) {
                results.append("✅ \(rel): language '\(language)' added (\(modified) keys marked for translation)")
            } else {
                results.append("⚠️ \(rel): failed to save")
            }
        }

        return .success(results.joined(separator: "\n"))
    }

    // MARK: - loc_remove_language

    /// Removes a target language from a .xcstrings file (or all files if path is empty).
    func removeLanguage(language: String, relativePath: String?) -> ToolResult {
        let files: [String]
        if let relativePath, !relativePath.isEmpty {
            files = [projectPath + "/" + relativePath]
        } else {
            files = findXCStringsFiles()
        }

        if files.isEmpty {
            return .failure("No .xcstrings files found.")
        }

        var results: [String] = []

        for filePath in files {
            let rel = filePath.replacingOccurrences(of: projectPath + "/", with: "")

            guard var xcstrings = loadXCStrings(at: filePath) else {
                results.append("⚠️ \(rel): failed to parse")
                continue
            }

            // Cannot remove source language
            if language == xcstrings.sourceLanguage {
                results.append("⚠️ \(rel): cannot remove source language '\(language)'")
                continue
            }

            var removed = 0
            for key in xcstrings.strings.keys {
                if xcstrings.strings[key]?.localizations?[language] != nil {
                    xcstrings.strings[key]?.localizations?.removeValue(forKey: language)
                    removed += 1
                }
            }

            if saveXCStrings(xcstrings, to: filePath) {
                results.append("✅ \(rel): language '\(language)' removed (\(removed) entries deleted)")
            } else {
                results.append("⚠️ \(rel): failed to save")
            }
        }

        return .success(results.joined(separator: "\n"))
    }

    // MARK: - loc_key_check

    /// Returns translation status for a specific key across all languages.
    func keyCheck(key: String, relativePath: String) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        guard let xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        guard let entry = xcstrings.strings[key] else {
            return .failure("Key '\(key)' not found in \(relativePath)")
        }

        var report = "🔑 Key: \"\(key)\"\n"
        if let comment = entry.comment {
            report += "   Comment: \(comment)\n"
        }
        report += "\n"

        let locs = entry.localizations ?? [:]
        if locs.isEmpty {
            report += "   No translations found.\n"
        } else {
            for lang in locs.keys.sorted() {
                let loc = locs[lang]
                let value = loc?.stringUnit?.value ?? ""
                let state = loc?.stringUnit?.state ?? "unknown"
                let icon = state == "translated" && !value.isEmpty ? "✅" : "⚠️"
                report += "   \(icon) \(lang.padding(toLength: 6, withPad: " ", startingAt: 0)) [\(state)] \"\(value)\"\n"
            }
        }

        return .success(report)
    }

    // MARK: - loc_next_batch

    /// Returns the next batch of keys needing translation.
    /// Batch size = 100 / number of target languages (never more than 100 translations at once).
    func nextBatch(relativePath: String) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        guard let xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        let sourceLanguage = xcstrings.sourceLanguage

        // Collect all target languages
        var allLanguages = Set<String>()
        for (_, entry) in xcstrings.strings {
            for lang in (entry.localizations ?? [:]).keys {
                allLanguages.insert(lang)
            }
        }
        let targetLanguages = allLanguages.subtracting([sourceLanguage]).sorted()

        if targetLanguages.isEmpty {
            return .success("No target languages found. Use loc_add_language to add languages.")
        }

        // Load batch state to skip already-handed-out keys
        let state = loadBatchState()
        let handedOut = state.handedOutKeys[relativePath] ?? []

        // Find keys that need translation in at least one target language
        var needsTranslation: [(key: String, missingLangs: [String])] = []

        for key in xcstrings.strings.keys.sorted() {
            if handedOut.contains(key) { continue }

            let entry = xcstrings.strings[key]!
            let locs = entry.localizations ?? [:]

            let missing = targetLanguages.filter { lang in
                guard let loc = locs[lang],
                      let unit = loc.stringUnit else { return true }
                return unit.value.isEmpty || unit.state != "translated"
            }

            if !missing.isEmpty {
                needsTranslation.append((key: key, missingLangs: missing))
            }
        }

        if needsTranslation.isEmpty {
            // Reset state for this file — all done
            var newState = state
            newState.handedOutKeys[relativePath] = []
            saveBatchState(newState)
            return .success("🎉 All keys are translated in \(relativePath)!\nBatch state reset — you can start a new round.")
        }

        // Batch size: 100 / n where n = number of target languages
        let batchSize = max(1, 100 / targetLanguages.count)
        let batch = Array(needsTranslation.prefix(batchSize))

        // Mark as handed out
        var newState = state
        var newHandedOut = handedOut
        for item in batch {
            newHandedOut.append(item.key)
        }
        newState.handedOutKeys[relativePath] = newHandedOut
        saveBatchState(newState)

        // Get source values for context
        var report = "📋 Next batch: \(batch.count) keys × \(targetLanguages.count) languages = up to \(batch.count * targetLanguages.count) translations\n"
        report += "File: \(relativePath)\n"
        report += "Target languages: \(targetLanguages.joined(separator: ", "))\n\n"
        report += "Keys to translate:\n\n"

        for item in batch {
            let sourceValue = xcstrings.strings[item.key]?.localizations?[sourceLanguage]?.stringUnit?.value ?? item.key
            report += "KEY: \"\(item.key)\"\n"
            report += "  EN: \"\(sourceValue)\"\n"
            report += "  Missing: \(item.missingLangs.joined(separator: ", "))\n\n"
        }

        report += "---\n"
        report += "Remaining after this batch: \(needsTranslation.count - batch.count) keys\n"
        report += "Use loc_submit_batch to submit translations for these keys."

        return .success(report)
    }

    // MARK: - loc_submit_batch

    /// Accepts translations and writes them to the xcstrings file without duplicates.
    /// translations format: JSON string like {"key": {"ru": "Привет", "de": "Hallo"}}
    func submitBatch(relativePath: String, translationsJSON: String) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        guard var xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        // Parse translations JSON
        guard let data = translationsJSON.data(using: .utf8),
              let translations = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return .failure("""
            Failed to parse translations JSON.
            Expected format:
            {
              "key1": {"ru": "Перевод", "de": "Übersetzung"},
              "key2": {"ru": "Другой", "de": "Anderer"}
            }
            """)
        }

        var added = 0
        var updated = 0
        var skipped = 0
        var notFound: [String] = []

        for (key, langValues) in translations {
            guard xcstrings.strings[key] != nil else {
                notFound.append(key)
                continue
            }

            if xcstrings.strings[key]?.localizations == nil {
                xcstrings.strings[key]?.localizations = [:]
            }

            for (lang, value) in langValues {
                let existing = xcstrings.strings[key]?.localizations?[lang]?.stringUnit?.value
                if existing == value {
                    skipped += 1
                    continue
                }

                let wasEmpty = existing == nil || existing!.isEmpty
                xcstrings.strings[key]?.localizations?[lang] = XCLocalization(
                    stringUnit: XCStringUnit(state: "translated", value: value)
                )
                if wasEmpty { added += 1 } else { updated += 1 }
            }
        }

        guard saveXCStrings(xcstrings, to: fullPath) else {
            return .failure("Failed to save \(relativePath)")
        }

        var report = "✅ Batch submitted to \(relativePath)\n"
        report += "   Added:   \(added)\n"
        report += "   Updated: \(updated)\n"
        report += "   Skipped (same value): \(skipped)\n"
        if !notFound.isEmpty {
            report += "   ⚠️ Keys not found (ignored): \(notFound.joined(separator: ", "))\n"
        }

        return .success(report)
    }

    // MARK: - loc_dead_keys

    /// Finds keys in xcstrings that are not used anywhere in .swift files.
    func deadKeys(relativePath: String) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        guard let xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        let keys = Array(xcstrings.strings.keys)
        if keys.isEmpty {
            return .success("No keys found in \(relativePath).")
        }

        // Scan all .swift files in project
        let swiftFiles = findSwiftFiles()
        var allSourceCode = ""
        for swiftFile in swiftFiles {
            if let content = try? String(contentsOfFile: swiftFile, encoding: .utf8) {
                allSourceCode += content + "\n"
            }
        }

        var deadKeys: [String] = []
        var usedKeys: [String] = []

        for key in keys.sorted() {
            // Check if key appears in source code (as string literal)
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
            report += "\nThese keys can be safely removed with loc_delete_key (if needed)."
        }

        return .success(report)
    }

    // MARK: - loc_add_key

    /// Adds a new key with English value and optional comment.
    func addKey(relativePath: String, key: String, englishValue: String, comment: String?) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        guard var xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        if xcstrings.strings[key] != nil {
            return .failure("Key '\(key)' already exists. Use loc_submit_batch to update translations.")
        }

        xcstrings.strings[key] = XCStringEntry(
            comment: comment,
            localizations: [
                xcstrings.sourceLanguage: XCLocalization(
                    stringUnit: XCStringUnit(state: "translated", value: englishValue)
                )
            ]
        )

        guard saveXCStrings(xcstrings, to: fullPath) else {
            return .failure("Failed to save \(relativePath)")
        }

        return .success("✅ Key added: \"\(key)\" = \"\(englishValue)\" (en)\nUse loc_next_batch to get it in the translation queue.")
    }

    // MARK: - loc_remove_key

    /// Removes a key from the xcstrings file.
    func removeKey(relativePath: String, key: String) -> ToolResult {
        let fullPath = projectPath + "/" + relativePath

        guard var xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        guard xcstrings.strings[key] != nil else {
            return .failure("Key '\(key)' not found in \(relativePath)")
        }

        xcstrings.strings.removeValue(forKey: key)

        guard saveXCStrings(xcstrings, to: fullPath) else {
            return .failure("Failed to save \(relativePath)")
        }

        return .success("✅ Key removed: \"\(key)\" from \(relativePath)")
    }

    // MARK: - Private Helpers

    /// Recursively finds all .xcstrings files in the project directory.
    private func findXCStringsFiles() -> [String] {
        var result: [String] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            if url.pathExtension == "xcstrings" {
                result.append(url.path)
            }
        }

        return result.sorted()
    }

    /// Recursively finds all .swift files in the project directory.
    private func findSwiftFiles() -> [String] {
        var result: [String] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            if url.pathExtension == "swift" {
                result.append(url.path)
            }
        }

        return result
    }

    /// Loads and decodes an .xcstrings file.
    private func loadXCStrings(at path: String) -> XCStringsFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(XCStringsFile.self, from: data)
    }

    /// Encodes and saves an .xcstrings file with pretty-printing.
    @discardableResult
    private func saveXCStrings(_ xcstrings: XCStringsFile, to path: String) -> Bool {
        guard let data = try? JSONEncoder.xcstrings.encode(xcstrings),
              let pretty = prettyPrint(data) else { return false }
        return (try? pretty.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Pretty-prints JSON data with 2-space indentation (Xcode standard).
    private func prettyPrint(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }

    // MARK: - Batch State

    private struct BatchState: Codable {
        var handedOutKeys: [String: [String]] = [:]
    }

    private func loadBatchState() -> BatchState {
        guard let data = FileManager.default.contents(atPath: batchStatePath),
              let state = try? JSONDecoder().decode(BatchState.self, from: data) else {
            return BatchState()
        }
        return state
    }

    private func saveBatchState(_ state: BatchState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: batchStatePath))
    }
}

// MARK: - JSONEncoder Extension

private extension JSONEncoder {
    /// Encoder configured for xcstrings output.
    static var xcstrings: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - XCStrings Data Models

/// Root structure of an .xcstrings file.
struct XCStringsFile: Codable {
    var sourceLanguage: String
    var strings: [String: XCStringEntry]
    var version: String

    enum CodingKeys: String, CodingKey {
        case sourceLanguage, strings, version
    }
}

/// A single string entry in the xcstrings file.
struct XCStringEntry: Codable {
    var comment: String?
    var localizations: [String: XCLocalization]?

    enum CodingKeys: String, CodingKey {
        case comment, localizations
    }
}

/// Localization for one language.
struct XCLocalization: Codable {
    var stringUnit: XCStringUnit?

    enum CodingKeys: String, CodingKey {
        case stringUnit
    }
}

/// The actual translated string with its state.
struct XCStringUnit: Codable {
    var state: String  // "translated" | "needs_review" | "new"
    var value: String

    enum CodingKeys: String, CodingKey {
        case state, value
    }
}
