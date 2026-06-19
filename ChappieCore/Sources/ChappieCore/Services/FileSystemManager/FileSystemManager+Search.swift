// FileSystemManager+Search.swift
// ChappieCore
//
// Text search: single-file and project-wide grep-like search.
// Returns matching lines with surrounding context windows.

import Foundation

extension FileSystemManager {

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

        for (wsName, wsURL) in targetWorkspaces {
            guard let enumerator = fileManager.enumerator(
                at: wsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
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
            }
        }

        if results.isEmpty {
            return "No matches found for '\(query)'."
        }

        return "Found matches in \(results.count) file(s):\n\n" + results.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    /// Builds match lines with surrounding context for a single file's line array.
    /// Returns empty string if no matches found.
    func buildSearchResult(
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
    func shouldSearchFile(_ url: URL, pattern: String?) -> Bool {
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
}
