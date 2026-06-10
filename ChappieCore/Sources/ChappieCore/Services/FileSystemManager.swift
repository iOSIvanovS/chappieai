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
