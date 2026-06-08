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

    public func listFiles() throws -> [String] {
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

                // Prefix with project name in multi-workspace mode.
                if name.isEmpty {
                    allPaths.append(relativePath)
                } else {
                    allPaths.append("\(name)/\(relativePath)")
                }
            }
        }

        return allPaths
    }

    public func readFile(at path: String) throws -> String {
        let (workspaceURL, relativePath) = try resolveWorkspace(for: path)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)
        do {
            return try String(contentsOf: safeURL, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError("Failed to read '\(path)': \(error.localizedDescription)")
        }
    }

    public func writeFile(at path: String, content: String) throws {
        let (workspaceURL, relativePath) = try resolveWorkspace(for: path)
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

    public func deleteFile(at path: String) throws {
        let (workspaceURL, relativePath) = try resolveWorkspace(for: path)
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
}
