// FileSystemManager+Data.swift
// ChappieCore
//
// Raw bytes of a project file, through the same path guard as every other file operation.
// Used by the json_* tools, which parse the bytes themselves and must not pay for a String copy.

import Foundation

extension FileSystemManager {

    /// Bytes of the file. Refuses a file over `limit` BEFORE reading it.
    public func readData(at path: String, projectName: String? = nil, limit: Int) throws -> Data {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)
        let real = safeURL.resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: real.path, isDirectory: &isDirectory) else {
            throw ChappieError.fileSystemError("File not found: '\(path)'")
        }
        guard !isDirectory.boolValue else {
            throw ChappieError.fileSystemError("'\(path)' is a folder, not a file.")
        }
        if let size = (try? fileManager.attributesOfItem(atPath: real.path))?[.size] as? NSNumber, size.intValue > limit {
            throw ChappieError.fileSystemError(
                "'\(path)' is \(size.intValue / 1024 / 1024) MB, over the \(limit / 1024 / 1024) MB limit of the json_* tools."
            )
        }
        do {
            return try Data(contentsOf: real, options: .mappedIfSafe)
        } catch {
            throw ChappieError.fileSystemError("Failed to read '\(path)': \(error.localizedDescription)")
        }
    }
}
