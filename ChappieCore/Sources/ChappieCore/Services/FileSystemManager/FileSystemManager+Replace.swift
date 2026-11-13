// FileSystemManager+Replace.swift
// ChappieCore
//
// Replaces the bytes of an existing project file only if it still holds exactly the bytes the caller
// based its edit on. Used by json_edit: the edit was computed on a copy read earlier, and writing it over
// a file that changed in between would silently undo someone else's change.

import Foundation

extension FileSystemManager {

    /// Writes `newData` atomically when the file still equals `original`.
    /// A symbolic link is followed (the target changes, the link stays) and permissions are kept.
    public func replaceData(at path: String, projectName: String? = nil, original: Data, with newData: Data) throws {
        let (workspaceURL, relativePath) = try resolveForOperation(path: path, projectName: projectName)
        let safeURL = try validateAndResolvePath(relativePath, in: workspaceURL)
        let real = safeURL.resolvingSymlinksInPath()

        guard fileManager.fileExists(atPath: real.path) else {
            throw ChappieError.fileSystemError("File not found: '\(path)'")
        }
        let current: Data
        do {
            current = try Data(contentsOf: real)
        } catch {
            throw ChappieError.fileSystemError("Failed to read '\(path)': \(error.localizedDescription)")
        }
        guard current == original else {
            throw ChappieError.fileSystemError("'\(path)' changed while the edit was being prepared. Nothing was written; read the file again and repeat the edit.")
        }

        let permissions = (try? fileManager.attributesOfItem(atPath: real.path))?[.posixPermissions]
        do {
            try newData.write(to: real, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: real.path)
            }
        } catch {
            throw ChappieError.fileSystemError("Failed to write '\(path)': \(error.localizedDescription)")
        }
    }
}
