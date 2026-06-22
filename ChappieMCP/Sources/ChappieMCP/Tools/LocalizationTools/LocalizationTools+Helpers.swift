// LocalizationTools+Helpers.swift
//
// WHY: Shared file I/O helpers and XCStrings data models used across all LocalizationTools extensions.

import Foundation

// MARK: - File I/O Helpers

extension LocalizationTools {

    /// Recursively finds all .xcstrings files across all registered project paths.
    /// WHY: projectPathMap may contain project-specific paths that differ from
    /// the workspace root. We must scan all of them to find every .xcstrings file.
    func findXCStringsFiles() -> [String] {
        var result: Set<String> = []
        let fm = FileManager.default

        // Build list of search roots: workspace root + all project-specific paths
        var searchRoots = [projectPath]
        for (_, path) in projectPathMap {
            if !searchRoots.contains(path) {
                searchRoots.append(path)
            }
        }

        for root in searchRoots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if url.pathExtension == "xcstrings" {
                    result.insert(url.path)
                }
            }
        }

        return result.sorted()
    }

    /// Recursively finds all .swift files in the project directory.
    func findSwiftFiles() -> [String] {
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

    /// Resolves a relative path to an absolute path by trying all known project roots.
    /// WHY: .xcstrings files may live in project-specific directories, not just the workspace root.
    /// Tries workspace root first, then each projectPathMap entry — returns the first match that exists.
    func resolveFullPath(_ relativePath: String) -> String {
        var roots = [projectPath]
        for (_, path) in projectPathMap { roots.append(path) }
        for root in roots {
            let candidate = root + "/" + relativePath
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        // Fallback: workspace root (caller will handle missing file)
        return projectPath + "/" + relativePath
    }

    /// Returns the shortest relative path by stripping the longest matching root prefix.
    /// WHY: files may live in project-specific paths outside the workspace root.
    func relativeToAnyRoot(_ absolutePath: String) -> String {
        var roots = [projectPath]
        for (_, path) in projectPathMap { roots.append(path) }
        // Sort descending by length so the most specific root wins
        let sorted = roots.sorted { $0.count > $1.count }
        for root in sorted {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if absolutePath.hasPrefix(prefix) {
                return String(absolutePath.dropFirst(prefix.count))
            }
        }
        return absolutePath
    }

    /// Loads and decodes an .xcstrings file.
    func loadXCStrings(at path: String) -> XCStringsFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(XCStringsFile.self, from: data)
    }

    /// Encodes and saves an .xcstrings file with pretty-printing.
    @discardableResult
    func saveXCStrings(_ xcstrings: XCStringsFile, to path: String) -> Bool {
        guard let data = try? JSONEncoder.xcstrings.encode(xcstrings),
              let pretty = prettyPrint(data) else { return false }
        return (try? pretty.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Pretty-prints JSON data with sorted keys (Xcode standard).
    func prettyPrint(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }
}

// MARK: - JSONEncoder Extension

extension JSONEncoder {
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
