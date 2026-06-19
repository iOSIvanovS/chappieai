// FileSystemManager.swift
// ChappieCore
//
// WHY MULTI-WORKSPACE:
// A thread can have multiple attached projects. Previously only the first project
// was accessible — all others were silently ignored (B-01).
// Now FileSystemManager holds a [name: URL] map. list_files returns "ProjectName/path",
// read/write/delete parse the prefix and route to the correct workspace.
//
// SINGLE-WORKSPACE COMPAT:
// init(workspaceURL:) still works — creates a single-entry map with key "".
// All existing callers (V1, tests) continue to work without changes.
// Single-workspace paths have no prefix — "file.swift" not "ProjectName/file.swift".
//
// SECURITY:
// Each workspace has its own validateAndResolvePath() guard (CWE-22).
// Cross-workspace traversal is impossible — routing is done by prefix, not by path.
//
// PROJECT PARAM ROUTING:
// read/write/delete accept an explicit projectName parameter (from args["project"]).
// WHY: AI now always passes "project" as a separate arg — path may be a bare filename
// like "readme.md" with no project prefix. Without explicit routing, resolveWorkspace()
// would fail to find a matching prefix and throw "Cannot route path".
// When projectName is provided — workspace is resolved by name, not by path prefix.
// When projectName is nil — falls back to prefix-based routing (backward compat).

import Foundation

public actor FileSystemManager {

    // MARK: - Storage

    /// Ordered list of (name, URL) pairs. Order matches the order projects were attached.
    /// WHY not Dictionary: order matters for list_files output consistency.
    private let workspaces: [(name: String, url: URL)]

    private let fileManager = FileManager.default

    // MARK: - Accessors

    /// First workspace URL — used by callers that still expect a single workspace.
    /// nonisolated: workspaces is a let constant, safe to read without actor hop.
    public nonisolated var workspaceURL: URL {
        workspaces.first?.url ?? URL(fileURLWithPath: "/")
    }

    /// All workspace names — used by FileTools to identify which project failed.
    /// nonisolated: workspaces is a let constant, safe to read without actor hop.
    public nonisolated var workspaceNames: [String] {
        workspaces.map(\.name).filter { !$0.isEmpty }
    }

    // MARK: - Init

    /// Single-workspace init — backward compatible. Paths have no project prefix.
    public init(workspaceURL: URL) {
        self.workspaces = [("", workspaceURL)]
    }

    /// Multi-workspace init. Each project name maps to its resolved URL.
    /// list_files returns "ProjectName/relative/path".
    /// read/write/delete accept "ProjectName/relative/path" and route accordingly.
    public init(workspaces: [(name: String, url: URL)]) {
        self.workspaces = workspaces
    }

    // MARK: - Security

    /// Resolves a relative path inside a specific workspace and validates it stays inside.
    /// Guards against Path Traversal (CWE-22).
    private func validateAndResolvePath(_ relativePath: String, in workspaceURL: URL) throws -> URL {
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath()
        let resolvedTarget = resolvedWorkspace
            .appendingPathComponent(relativePath)
            .standardized

        // Trailing slash prevents false prefix match: "/foo/bar" vs "/foo/barbaz"
        let workspacePath = resolvedWorkspace.path.hasSuffix("/")
            ? resolvedWorkspace.path
            : resolvedWorkspace.path + "/"

        let targetPath = resolvedTarget.path
        let isInside = targetPath == resolvedWorkspace.path || targetPath.hasPrefix(workspacePath)

        guard isInside else {
            throw ChappieError.fileSystemError(
                "Path traversal blocked: '\(relativePath)' resolves to '\(targetPath)' outside workspace '\(resolvedWorkspace.path)'"
            )
        }

        return resolvedTarget
    }

    // MARK: - Routing

    /// Resolves workspace by explicit project name.
    /// WHY: AI passes project= separately — path may be a bare filename with no prefix.
    private func resolveWorkspace(byName name: String) throws -> URL {
        guard let workspace = workspaces.first(where: { $0.name == name }) else {
            throw ChappieError.fileSystemError(
                "Project '\(name)' not found. Available: \(workspaces.map(\.name).joined(separator: ", "))"
            )
        }
        return workspace.url
    }

    /// Splits "ProjectName/relative/path" into (workspace URL, "relative/path").
    /// For single-workspace mode (name == "") — returns the only workspace and the path as-is.
    private func resolveWorkspace(for path: String) throws -> (url: URL, relativePath: String) {
        // Single-workspace mode: no prefix stripping needed.
        if workspaces.count == 1 && workspaces[0].name == "" {
            return (workspaces[0].url, path)
        }

        // Multi-workspace mode: path must start with "ProjectName/".
        for (name, url) in workspaces {
            let prefix = name + "/"
            if path.hasPrefix(prefix) {
                let relativePath = String(path.dropFirst(prefix.count))
                return (url, relativePath)
            }
            // Also allow exact match with project name (e.g. list_files result = just the folder).
            if path == name {
                return (url, "")
            }
        }

        throw ChappieError.fileSystemError(
            "Cannot route path '\(path)': no attached project matches. " +
            "Available projects: \(workspaces.map(\.name).joined(separator: ", "))"
        )
    }

    // MARK: - Public API

    /// List files across all attached workspaces.
    public func listFiles() throws -> [String] {
        try listFilesIn(workspaces: workspaces)
    }

    /// List files for a specific project only.
    /// WHY: AI passes project= to scope the listing — avoids mixing all projects in one dump.
    /// Returns the same prefixed format as listFiles() for consistency.
    public func listFiles(project: String) throws -> [String] {
        guard let workspace = workspaces.first(where: { $0.name == project }) else {
            throw ChappieError.fileSystemError(
                "Project '\(project)' not found. Available: \(workspaces.map(\.name).joined(separator: ", "))"
            )
        }
        return try listFilesIn(workspaces: [workspace])
    }

    // MARK: - Search in file

    /// Search for a query string in a single file. Returns matching lines with context.
    /// WHY: avoids reading the entire file into AI context just to find one line.
    public func searchInFile(
        path: String,
        projectName: String?,
        query: String,
        contextLines: Int
    ) throws -> String {
        let content = try readFile(at: path, projectName: projectName)
        let lines = content.components(separatedBy: "\n")
        return buildSearchResult(
            lines: lines,
            query: query,
            contextLines: contextLines,
            filePath: path
        )
    }

    // MARK: - Search in project

    /// Search for a query string across all files in a project (or all projects).
    /// WHY: grep-like navigation without reading every file individually.
    public func searchInProject(
        query: String,
        projectName: String?,
        filePattern: String?,
        contextLines: Int
    ) throws -> String {
        let targetWorkspaces: [(name: String, url: URL)]
        if let name = projectName, !name.isEmpty {
            guard let ws = workspaces.first(where: { $0.name == name }) else {
                throw ChappieError.fileSystemError(
                    "Project '\(name)' not found. Available: \(workspaces.map(\.name).joined(separator: ", "))"
                )
            }
            targetWorkspaces = [ws]
        } else {
            targetWorkspaces = workspaces
        }

        var results: [String] = []
        var totalMatches = 0

        for (wsName, wsURL) in targetWorkspaces {
            guard let enumerator = fileManager.enumerator(
                at: wsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                // Skip binary/large files and non-matching patterns
                guard shouldSearchFile(fileURL, pattern: filePattern) else { continue }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

                let lines = content.components(separatedBy: "\n")
                let fileResult = buildSearchResult(lines: lines, query: query, contextLines: contextLines, filePath: nil)
                guard !fileResult.isEmpty else { continue }

                // Build display path with project prefix
                let resolvedWS = wsURL.resolvingSymlinksInPath()
                let resolvedFile = fileURL.resolvingSymlinksInPath()
                var relativePath = resolvedFile.path.replacingOccurrences(of: resolvedWS.path + "/", with: "")
                if relativePath == resolvedFile.path {
                    relativePath = fileURL.path.replacingOccurrences(of: wsURL.path + "/", with: "")
                }
                let displayPath = wsName.isEmpty ? relativePath : "\(wsName)/\(relativePath)"

                results.append("📄 \(displayPath)\n\(fileResult)")
                totalMatches += fileResult.components(separatedBy: "\n").filter { $0.hasPrefix("  ") }.count
            }
        }

        if results.isEmpty {
            return "No matches found for '\(query)'."
        }

        let header = "Found matches in \(results.count) file(s):\n\n"
        return header + results.joined(separator: "\n\n")
    }

    // MARK: - Search helpers

    /// Builds match lines with surrounding context for a single file's line array.
    /// Returns empty string if no matches found.
    private func buildSearchResult(
        lines: [String],
        query: String,
        contextLines: Int,
        filePath: String?
    ) -> String {
        let lowQuery = query.lowercased()
        var matchIndices: [Int] = []

        for (i, line) in lines.enumerated() {
            if line.lowercased().contains(lowQuery) {
                matchIndices.append(i)
            }
        }

        guard !matchIndices.isEmpty else { return "" }

        // Merge overlapping context windows into contiguous blocks
        var blocks: [(start: Int, end: Int)] = []
        for idx in matchIndices {
            let start = max(0, idx - contextLines)
            let end = min(lines.count - 1, idx + contextLines)
            if let last = blocks.last, start <= last.end + 1 {
                blocks[blocks.count - 1] = (last.start, max(last.end, end))
            } else {
                blocks.append((start, end))
            }
        }

        var output: [String] = []
        if let path = filePath {
            output.append("📄 \(path)")
        }

        for block in blocks {
            if block.start > 0 { output.append("  ...") }
            for lineIdx in block.start...block.end {
                let lineNum = lineIdx + 1
                let line = lines[lineIdx]
                let isMatch = line.lowercased().contains(lowQuery)
                // Mark matching lines with ▶ for easy scanning
                let prefix = isMatch ? "▶ \(lineNum): " : "  \(lineNum): "
                output.append(prefix + line)
            }
            if block.end < lines.count - 1 { output.append("  ...") }
        }

        return output.joined(separator: "\n")
    }

    /// Returns true if the file should be included in project-wide search.
    /// Skips binary extensions and applies optional glob pattern filter.
    private func shouldSearchFile(_ url: URL, pattern: String?) -> Bool {
        let ext = url.pathExtension.lowercased()

        // Skip known binary/asset extensions — they can't contain text matches
        let binaryExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "ico", "icns",
            "pdf", "zip", "gz", "tar", "dmg", "pkg",
            "mp3", "mp4", "mov", "m4a", "aac",
            "ttf", "otf", "woff", "woff2",
            "xcuserstate", "o", "a", "dylib", "so",
            "pb", "bin", "dat"
        ]
        if binaryExtensions.contains(ext) { return false }

        // Apply file pattern filter (e.g. "*.swift", "*.ts")
        if let pattern = pattern, !pattern.isEmpty {
            let glob = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
            if !ext.isEmpty && ext != glob && url.lastPathComponent != pattern {
                return false
            }
        }

        return true
    }

    // MARK: - Private listing

    private func listFilesIn(workspaces: [(name: String, url: URL)]) throws -> [String] {
        var allPaths: [String] = []

        for (name, url) in workspaces {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw ChappieError.fileSystemError("Cannot access directory: \(url.path)")
            }

            let resolvedURL = url.resolvingSymlinksInPath()

            for case let fileURL as URL in enumerator {
                let resolvedFile = fileURL.resolvingSymlinksInPath()
                var relativePath = resolvedFile.path.replacingOccurrences(
                    of: resolvedURL.path + "/", with: ""
                )
                // Fallback: if symlink resolution produced different prefix, strip original.
                if relativePath == resolvedFile.path {
                    relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                }

                if name.isEmpty {
                    allPaths.append(relativePath)
                } else {
                    allPaths.append("\(name)/\(relativePath)")
                }
            }
        }

        return allPaths
    }

    // MARK: - File operations
    // projectName: explicit project from args["project"] — used when path has no prefix.
    // Falls back to prefix-based routing when projectName is nil (backward compat).

    public func readFile(at path: String, projectName: String? = nil) throws -> String {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)
        do {
            return try String(contentsOf: safeURL, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError("Failed to read '\(path)': \(error.localizedDescription)")
        }
    }

    public func writeFile(at path: String, content: String, projectName: String? = nil) throws {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)
        let directoryURL = safeURL.deletingLastPathComponent()
        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            // atomically: true — write is all-or-nothing, prevents partial corruption on crash
            try content.write(to: safeURL, atomically: true, encoding: .utf8)
        } catch let chappieError as ChappieError {
            throw chappieError
        } catch {
            throw ChappieError.fileSystemError("Failed to write '\(path)': \(error.localizedDescription)")
        }
    }

    public func deleteFile(at path: String, projectName: String? = nil) throws {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)
        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw ChappieError.fileSystemError("File not found: '\(path)'")
        }
        do {
            try fileManager.removeItem(at: safeURL)
        } catch {
            throw ChappieError.fileSystemError("Failed to delete '\(path)': \(error.localizedDescription)")
        }
    }

    // MARK: - File info

    /// Returns metadata for a file: size, line count, last modified date.
    /// WHY: avoids reading the entire file just to know its size or line count.
    public func getFileInfo(at path: String, projectName: String? = nil) throws -> String {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)

        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw ChappieError.fileSystemError("File not found: '\(path)'")
        }

        let attrs = try fileManager.attributesOfItem(atPath: safeURL.path)
        let size = attrs[.size] as? Int ?? 0
        let modDate = attrs[.modificationDate] as? Date

        // Count lines without loading the full content into a String
        let lineCount: Int
        if let data = try? Data(contentsOf: safeURL) {
            lineCount = data.filter { $0 == UInt8(ascii: "\n") }.count + 1
        } else {
            lineCount = 0
        }

        let formatter = ISO8601DateFormatter()
        let modString = modDate.map { formatter.string(from: $0) } ?? "unknown"

        let sizeFormatted: String
        if size < 1024 {
            sizeFormatted = "\(size) B"
        } else if size < 1024 * 1024 {
            sizeFormatted = String(format: "%.1f KB", Double(size) / 1024)
        } else {
            sizeFormatted = String(format: "%.1f MB", Double(size) / (1024 * 1024))
        }

        return """
        path: \(path)
        size: \(sizeFormatted) (\(size) bytes)
        lines: \(lineCount)
        modified: \(modString)
        """
    }

    // MARK: - Move / Rename

    /// Moves or renames a file within the same project workspace.
    /// WHY: cheaper than read_file → write_file → delete_file (3 ops → 1 op, no content in context).
    public func moveFile(from sourcePath: String, to destPath: String, projectName: String? = nil) throws {
        let (sourceWorkspaceURL, sourceRelative) = try resolveForOperation(path: sourcePath, projectName: projectName)
        let (destWorkspaceURL, destRelative)     = try resolveForOperation(path: destPath,   projectName: projectName)

        let safeSource = try validateAndResolvePath(sourceRelative, in: sourceWorkspaceURL)
        let safeDest   = try validateAndResolvePath(destRelative,   in: destWorkspaceURL)

        guard fileManager.fileExists(atPath: safeSource.path) else {
            throw ChappieError.fileSystemError("Source file not found: '\(sourcePath)'")
        }

        // Create destination directory if needed
        let destDir = safeDest.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: safeDest.path) {
            throw ChappieError.fileSystemError(
                "Destination already exists: '\(destPath)'. Delete it first or choose a different name."
            )
        }

        do {
            try fileManager.moveItem(at: safeSource, to: safeDest)
        } catch {
            throw ChappieError.fileSystemError(
                "Failed to move '\(sourcePath)' → '\(destPath)': \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Patch file

    /// Replaces an exact block of text in a file without reading the whole file into AI context.
    /// WHY: surgical edits after search_in_file cost ~200 tokens vs ~6000 for read→write.
    ///
    /// Safety policy (exactlyOne by default):
    ///   - 0 matches → error: find block not found, nothing changed.
    ///   - 1 match   → replace, write atomically.
    ///   - 2+ matches → error: ambiguous, nothing changed. Use a longer find block.
    public func patchFile(
        at path: String,
        find: String,
        replace: String,
        projectName: String? = nil
    ) throws -> String {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)

        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw ChappieError.fileSystemError("File not found: '\(path)'")
        }

        let content: String
        do {
            content = try String(contentsOf: safeURL, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError("Failed to read '\(path)': \(error.localizedDescription)")
        }

        // Count occurrences to enforce exactlyOne policy
        var count = 0
        var searchRange = content.startIndex..<content.endIndex
        while let range = content.range(of: find, options: .literal, range: searchRange) {
            count += 1
            if count > 1 { break } // no need to count further
            searchRange = range.upperBound..<content.endIndex
        }

        switch count {
        case 0:
            return "Error: patch_file — find block not found in '\(path)'. Nothing changed.\nMake sure the find block matches the file exactly (including indentation and whitespace)."
        case 1:
            let patched = content.replacingOccurrences(of: find, with: replace, options: .literal)
            do {
                // atomically: true — write is all-or-nothing, prevents partial corruption on crash
                try patched.write(to: safeURL, atomically: true, encoding: .utf8)
            } catch {
                throw ChappieError.fileSystemError("Failed to write patch to '\(path)': \(error.localizedDescription)")
            }
            return "Success: patch applied to '\(path)'."
        default:
            return "Error: patch_file — find block matches \(count) locations in '\(path)'. Nothing changed.\nUse a longer, more unique find block (at least 3–5 lines) to make the match unambiguous."
        }
    }

    // MARK: - Private routing helper

    /// Resolves workspace and relative path for a file operation.
    /// WHY: when projectName is provided — route by name (AI passes bare path + project arg).
    /// When nil — route by path prefix (legacy / single-workspace compat).
    private func resolveForOperation(path: String, projectName: String?) throws -> (url: URL, relativePath: String) {
        if let name = projectName, !name.isEmpty {
            let url = try resolveWorkspace(byName: name)
            // Path may already contain the project prefix (e.g. "ProjectName/file.md") — strip it.
            let prefix = name + "/"
            let relativePath = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            return (url, relativePath)
        }
        return try resolveWorkspace(for: path)
    }
}
