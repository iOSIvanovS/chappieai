// FileSystemManager+Listing.swift
// ChappieCore
//
// List files across one or all attached workspaces.
// Returns prefixed paths ("ProjectName/relative/path") in multi-workspace mode.

import Foundation

extension FileSystemManager {

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

    // MARK: - Private

    func listFilesIn(workspaces: [(name: String, url: URL)]) throws -> [String] {
        var allPaths: [String] = []

        for (name, url) in workspaces {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw ChappieError.fileSystemError("Cannot access directory: \(url.path)")
            }

            let resolvedURL = url.resolvingSymlinksInPath()
            let realRoot = PathGuard.realRoot(of: url)

            for case let fileURL as URL in enumerator {
                // The enumerator never descends into symlinked folders, so only the entry itself
                // can be a link; hide those pointing outside the project (they are unreadable anyway).
                if let realRoot,
                   (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                   PathGuard.escapes(fileURL, realRoot: realRoot) {
                    continue
                }
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
}
