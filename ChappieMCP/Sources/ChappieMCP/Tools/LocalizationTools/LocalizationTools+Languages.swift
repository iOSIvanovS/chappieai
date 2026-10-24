// LocalizationTools+Languages.swift
//
// WHY: Add/remove target languages from .xcstrings files.

import Foundation

extension LocalizationTools {

    // MARK: - loc_add_language

    /// Adds a target language to a .xcstrings file (or all files if path is empty).
    func addLanguage(language: String, relativePath: String?) -> ToolResult {
        let files: [String]
        if let relativePath, !relativePath.isEmpty {
            do { files = [try resolveFullPath(relativePath)] } catch { return .failure("\(error)") }
        } else {
            files = findXCStringsFiles()
        }

        if files.isEmpty {
            return .failure("No .xcstrings files found. Use loc_create first.")
        }

        var results: [String] = []

        for filePath in files {
            let rel = relativeToAnyRoot(filePath)

            guard var xcstrings = loadXCStrings(at: filePath) else {
                results.append("⚠️ \(rel): failed to parse")
                continue
            }

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
            do { files = [try resolveFullPath(relativePath)] } catch { return .failure("\(error)") }
        } else {
            files = findXCStringsFiles()
        }

        if files.isEmpty {
            return .failure("No .xcstrings files found.")
        }

        var results: [String] = []

        for filePath in files {
            let rel = relativeToAnyRoot(filePath)

            guard var xcstrings = loadXCStrings(at: filePath) else {
                results.append("⚠️ \(rel): failed to parse")
                continue
            }

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
}
