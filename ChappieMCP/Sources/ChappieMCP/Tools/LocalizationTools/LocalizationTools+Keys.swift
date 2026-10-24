// LocalizationTools+Keys.swift
//
// WHY: CRUD operations for individual localization keys.

import Foundation

extension LocalizationTools {

    // MARK: - loc_add_key

    /// Adds a new key with English value and optional comment.
    func addKey(relativePath: String, key: String, englishValue: String, comment: String?) -> ToolResult {
        let fullPath: String
        do { fullPath = try resolveFullPath(relativePath) } catch { return .failure("\(error)") }

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

    /// Removes a key and all its translations from the xcstrings file.
    func removeKey(relativePath: String, key: String) -> ToolResult {
        let fullPath: String
        do { fullPath = try resolveFullPath(relativePath) } catch { return .failure("\(error)") }

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

    // MARK: - loc_rename_key

    /// Renames a single key, preserving all existing translations.
    func renameKey(relativePath: String, oldKey: String, newKey: String) -> ToolResult {
        let fullPath: String
        do { fullPath = try resolveFullPath(relativePath) } catch { return .failure("\(error)") }

        guard var xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        guard let entry = xcstrings.strings[oldKey] else {
            return .failure("Key '\(oldKey)' not found in \(relativePath)")
        }

        if xcstrings.strings[newKey] != nil {
            return .failure("Key '\(newKey)' already exists. Remove it first or choose a different name.")
        }

        xcstrings.strings[newKey] = entry
        xcstrings.strings.removeValue(forKey: oldKey)

        guard saveXCStrings(xcstrings, to: fullPath) else {
            return .failure("Failed to save \(relativePath)")
        }

        let langCount = (entry.localizations ?? [:]).count
        return .success("✅ Key renamed: \"\(oldKey)\" → \"\(newKey)\" (\(langCount) translations preserved)")
    }

    // MARK: - loc_rename_keys (batch)

    /// Renames multiple keys in a single file write — cheaper than calling renameKey N times.
    /// WHY: file is loaded once, all renames applied in memory, saved once.
    func renameKeys(relativePath: String, renamesJSON: String) -> ToolResult {
        let fullPath: String
        do { fullPath = try resolveFullPath(relativePath) } catch { return .failure("\(error)") }

        guard var xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        guard let data = renamesJSON.data(using: .utf8),
              let renames = try? JSONDecoder().decode([[String: String]].self, from: data) else {
            return .failure("""
            Failed to parse renames JSON.
            Expected format:
            [
              {"old_key": "sidebar.old_title", "new_key": "sidebar.title"},
              {"old_key": "common.old_cancel", "new_key": "common.cancel"}
            ]
            """)
        }

        var renamed = 0
        var errors: [String] = []

        for item in renames {
            guard let oldKey = item["old_key"], let newKey = item["new_key"] else {
                errors.append("⚠️ Missing old_key or new_key in item: \(item)")
                continue
            }

            guard let entry = xcstrings.strings[oldKey] else {
                errors.append("⚠️ Key not found: \"\(oldKey)\"")
                continue
            }

            if xcstrings.strings[newKey] != nil {
                errors.append("⚠️ Target key already exists: \"\(newKey)\" (skipped \"\(oldKey)\")")
                continue
            }

            xcstrings.strings[newKey] = entry
            xcstrings.strings.removeValue(forKey: oldKey)
            renamed += 1
        }

        guard saveXCStrings(xcstrings, to: fullPath) else {
            return .failure("Failed to save \(relativePath)")
        }

        var report = "✅ Batch rename complete: \(renamed)/\(renames.count) keys renamed in \(relativePath)"
        if !errors.isEmpty {
            report += "\n\nIssues:\n" + errors.joined(separator: "\n")
        }
        return .success(report)
    }

    // MARK: - loc_key_check

    /// Returns translation status for a specific key across all languages.
    func keyCheck(key: String, relativePath: String) -> ToolResult {
        let fullPath: String
        do { fullPath = try resolveFullPath(relativePath) } catch { return .failure("\(error)") }

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

    // MARK: - loc_list_keys

    /// Returns all keys in the file with optional substring filter.
    /// WHY: needed to audit the file and plan batch rename operations.
    func listKeys(relativePath: String, filter: String?) -> ToolResult {
        let fullPath: String
        do { fullPath = try resolveFullPath(relativePath) } catch { return .failure("\(error)") }

        guard let xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        let sourceLanguage = xcstrings.sourceLanguage
        var keys = xcstrings.strings.keys.sorted()

        if let filter, !filter.isEmpty {
            keys = keys.filter { $0.localizedCaseInsensitiveContains(filter) }
        }

        if keys.isEmpty {
            let filterNote = filter != nil ? " matching '\(filter!)'" : ""
            return .success("No keys found\(filterNote) in \(relativePath).")
        }

        var report = "🔑 Keys in \(relativePath): \(keys.count)"
        if let filter { report += " (filter: '\(filter)')" }
        report += "\n\n"

        for key in keys {
            let enValue = xcstrings.strings[key]?.localizations?[sourceLanguage]?.stringUnit?.value ?? ""
            // Non-ASCII keys are raw strings (e.g. Cyrillic literals) — flag them
            let isDotKey = key.unicodeScalars.allSatisfy { $0.isASCII }
            let marker = isDotKey ? "  " : "⚠️"
            report += "\(marker) \"\(key)\"\n"
            if !enValue.isEmpty && enValue != key {
                report += "     en: \"\(enValue)\"\n"
            }
        }

        return .success(report)
    }
}
