// FileSystemManager+Size.swift
// ChappieCore
//
// Size of a project file in bytes, through the same path guard as every other file operation.
// Lets read_file refuse an oversized file BEFORE loading it into memory (OutputGuard.readLimit).

import Foundation

extension FileSystemManager {

    /// Size of the file the path points to (symlinks followed), or nil when it cannot be determined.
    public func fileByteSize(at path: String, projectName: String? = nil) throws -> Int? {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)
        // The guard returns the logical path; attributesOfItem on a symlink would report the link itself.
        let attributes = try? fileManager.attributesOfItem(atPath: safeURL.resolvingSymlinksInPath().path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }
}
