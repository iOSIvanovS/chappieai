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

        for root in usableRoots() {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let realRoot = PathGuard.realRoot(of: URL(fileURLWithPath: root))
            for case let url as URL in enumerator {
                guard url.pathExtension == "xcstrings" else { continue }
                if let realRoot, PathGuard.escapes(url, realRoot: realRoot) { continue }
                result.insert(url.path)
            }
        }

        return result.sorted()
    }

    /// Recursively finds all .swift files under the given roots (symlinks leading outside are skipped).
    func findSwiftFiles(in roots: [String]) -> [String] {
        var result: [String] = []
        let fm = FileManager.default

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let realRoot = PathGuard.realRoot(of: URL(fileURLWithPath: root))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if let realRoot, PathGuard.escapes(url, realRoot: realRoot) { continue }
                result.append(url.path)
            }
        }

        return result
    }

    /// Project roots the loc tools may touch: the workspace folder plus every attached project.
    /// WHY filtered: the helper can be started without a workspace (argv[1] = "/" or empty);
    /// such a root would make PathGuard hollow and let loc_info/loc_dead_keys scan the whole disk.
    func usableRoots() -> [String] {
        var roots: [String] = []
        for path in [projectPath] + projectPathMap.values.sorted()
        where PathGuard.isUsableRoot(path) && !roots.contains(path) {
            roots.append(path)
        }
        return roots
    }

    /// The usable root whose real (symlink-free) location contains `fullPath`.
    func root(containing fullPath: String) -> String? {
        usableRoots().first { root in
            guard let real = PathGuard.realRoot(of: URL(fileURLWithPath: root)) else { return false }
            return fullPath.hasPrefix(real + "/")
        }
    }

    /// Resolves a relative path to an absolute path by trying all known project roots.
    /// WHY: .xcstrings files may live in project-specific directories, not just the workspace root.
    /// Tries each usable root in order — returns the first match that exists.
    /// Throws PathGuard.Violation for absolute paths, "..", symlinks leading outside the root,
    /// or when no usable project folder exists at all.
    func resolveFullPath(_ relativePath: String) throws -> String {
        let roots = usableRoots()
        guard !roots.isEmpty else { throw Self.noProjectFolder }
        var fallback: String?
        for root in roots {
            let candidate = try PathGuard.resolve(relativePath, inRoot: URL(fileURLWithPath: root)).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            fallback = fallback ?? candidate
        }
        // Caller reports the missing file.
        return fallback ?? ""
    }

    /// Picks the root for a file that does not exist yet (loc_create): the only root, or the one
    /// where the target folder already exists. Guessing between several projects would write
    /// into the wrong one, so that case is an explicit error.
    func resolveNewFilePath(_ relativePath: String) throws -> String {
        let roots = usableRoots()
        guard !roots.isEmpty else { throw Self.noProjectFolder }

        var candidates: [String] = []
        var firstError: Error?
        for root in roots {
            do { candidates.append(try PathGuard.resolve(relativePath, inRoot: URL(fileURLWithPath: root)).path) }
            catch { firstError = firstError ?? error }
        }
        guard let first = candidates.first else { throw firstError ?? Self.noProjectFolder }
        if roots.count == 1 { return first }

        let existingParent = candidates.first {
            var isDir: ObjCBool = false
            let parent = URL(fileURLWithPath: $0).deletingLastPathComponent().path
            return FileManager.default.fileExists(atPath: parent, isDirectory: &isDir) && isDir.boolValue
        }
        if let existingParent { return existingParent }
        throw PathGuard.Violation(message: "Cannot tell which project '\(relativePath)' belongs to: its folder does not exist in any attached project. Create the folder first or use a path that starts with an existing folder.")
    }

    static var noProjectFolder: PathGuard.Violation {
        PathGuard.Violation(message: "No project folder is available. Attach a project to the thread first.")
    }

    /// Only .xcstrings files may be created, renamed or deleted by loc_* tools.
    func requireXCStringsExtension(_ relativePath: String) -> ToolResult? {
        URL(fileURLWithPath: relativePath).pathExtension.lowercased() == "xcstrings"
            ? nil
            : .failure("Only .xcstrings files are allowed here: '\(relativePath)'")
    }

    /// Returns the shortest relative path by stripping the longest matching root prefix.
    /// WHY: files may live in project-specific paths outside the workspace root.
    func relativeToAnyRoot(_ absolutePath: String) -> String {
        var roots = usableRoots()
        // Guarded paths are built on the symlink-free root, so strip that form as well.
        roots += roots.compactMap { PathGuard.realRoot(of: URL(fileURLWithPath: $0)) }
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
