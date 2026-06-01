//
//  FileSystemManager.swift
//  ChappieCore
//

import Foundation

/// File system access for the AI agent. All operations are sandboxed to `workspaceURL`.
public actor FileSystemManager {
    public let workspaceURL: URL
    private let fileManager = FileManager.default

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - Security

    /// Resolves a relative path and validates it stays inside `workspaceURL`.
    /// Guards against Path Traversal (CWE-22): LLM responses may contain `../../etc/passwd`-style paths.
    /// Both workspace and target are standardized + symlinks resolved before comparison.
    private func validateAndResolvePath(_ relativePath: String) throws -> URL {
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

    // MARK: - Public API

    public func listFiles() throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ChappieError.fileSystemError("Cannot access directory: \(workspaceURL.path)")
        }

        var filePaths: [String] = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: workspaceURL.path + "/", with: "")
            filePaths.append(relativePath)
        }
        return filePaths
    }

    public func readFile(at relativePath: String) throws -> String {
        let safeURL = try validateAndResolvePath(relativePath)
        do {
            return try String(contentsOf: safeURL, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError("Failed to read '\(relativePath)': \(error.localizedDescription)")
        }
    }

    public func writeFile(at relativePath: String, content: String) throws {
        let safeURL = try validateAndResolvePath(relativePath)
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
            throw ChappieError.fileSystemError("Failed to write '\(relativePath)': \(error.localizedDescription)")
        }
    }

    public func deleteFile(at relativePath: String) throws {
        let safeURL = try validateAndResolvePath(relativePath)
        guard fileManager.fileExists(atPath: safeURL.path) else {
            throw ChappieError.fileSystemError("File not found: '\(relativePath)'")
        }
        do {
            try fileManager.removeItem(at: safeURL)
        } catch {
            throw ChappieError.fileSystemError("Failed to delete '\(relativePath)': \(error.localizedDescription)")
        }
    }
}
