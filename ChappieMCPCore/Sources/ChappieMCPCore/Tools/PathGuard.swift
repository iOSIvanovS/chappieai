// PathGuard.swift
// ChappieCore
//
// Containment check for AI-supplied paths: blocks "..", absolute paths and symlinks
// that lead outside a project root (CWE-22 + symlink escape).
//
// WHY TWO COPIES: ChappieMCP is a separate executable and cannot import ChappieCore.
// ChappieMCPCore/Sources/ChappieMCPCore/Tools/PathGuard.swift MUST stay byte-identical to this file;
// PathGuardParityTests fails as soon as they drift apart.

import Foundation

enum PathGuard {

    struct Violation: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    // MARK: - Relative paths

    /// Validates `relativePath` against `root` and returns the logical URL (symlinks NOT replaced),
    /// so delete/move act on a link itself, exactly as before. Safety comes from checking where
    /// the deepest existing ancestor really points, not from the text of the path.
    static func resolve(_ relativePath: String, inRoot root: URL) throws -> URL {
        guard !relativePath.contains("\0") else {
            throw Violation(message: "Path contains a NUL byte")
        }
        guard !relativePath.hasPrefix("/") else {
            throw Violation(message: "Absolute paths are not allowed: '\(relativePath)'. Use a path relative to the project root.")
        }
        let parts = components(of: relativePath)
        guard !parts.contains("..") else {
            throw Violation(message: "'..' is not allowed in paths: '\(relativePath)'")
        }
        guard let realRoot = realPath(root.path) else {
            throw Violation(message: "Project root is not accessible: '\(root.path)'")
        }
        // A root of "/" makes every path "inside" and the whole guard hollow.
        guard realRoot != "/" else {
            throw Violation(message: "The filesystem root is not a valid project folder")
        }

        // Walk up to the deepest component that exists on disk (lstat, so a dangling link counts).
        var existingCount = parts.count
        while existingCount > 0, !lexists(join(realRoot, parts[0..<existingCount])) {
            existingCount -= 1
        }
        let existing = join(realRoot, parts[0..<existingCount])
        guard let realExisting = realPath(existing) else {
            throw Violation(message: "'\(relativePath)' cannot be resolved (broken symbolic link?)")
        }
        guard isInside(realExisting, root: realRoot) else {
            throw Violation(message: "'\(relativePath)' resolves outside the project (symbolic link)")
        }
        return URL(fileURLWithPath: join(realRoot, parts[...]))
    }

    // MARK: - Absolute paths (narrow exception)

    /// Accepts an absolute path only when it lies inside one of `allowedRoots`
    /// (e.g. the app's attachment store, whose paths the app itself hands to the helper).
    static func resolveAbsolute(_ absolutePath: String, allowedRoots: [URL]) throws -> URL {
        guard absolutePath.hasPrefix("/"), !absolutePath.contains("\0") else {
            throw Violation(message: "Invalid absolute path")
        }
        let parts = components(of: absolutePath)
        guard !parts.contains("..") else {
            throw Violation(message: "'..' is not allowed in paths: '\(absolutePath)'")
        }
        let normalized = "/" + parts.joined(separator: "/")

        for root in allowedRoots {
            let rootPaths = [root.standardizedFileURL.path, realPath(root.path)].compactMap { $0 }
            for rootPath in rootPaths where rootPath != "/" && normalized.hasPrefix(rootPath + "/") {
                return try resolve(String(normalized.dropFirst(rootPath.count + 1)), inRoot: root)
            }
        }
        throw Violation(message: "Absolute paths are not allowed: '\(absolutePath)'. Use a path relative to the project root.")
    }

    // MARK: - Root validation

    /// True for an existing absolute folder that is not the filesystem root. Empty strings are
    /// rejected too: `URL(fileURLWithPath: "")` silently means "current directory".
    static func isUsableRoot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), let real = realPath(path) else { return false }
        return real != "/"
    }

    // MARK: - Enumeration helpers

    /// Real (symlink-free) path of a root, or nil when it does not exist.
    static func realRoot(of url: URL) -> String? {
        realPath(url.path)
    }

    /// True when `url` is a dangling link or really lives outside `realRoot`.
    /// Used by listing/search to skip symlinks that would leak outside files.
    static func escapes(_ url: URL, realRoot: String) -> Bool {
        guard let real = realPath(url.path) else { return true }
        return !isInside(real, root: realRoot)
    }

    // MARK: - Internals

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
    }

    private static func join<S: Sequence>(_ root: String, _ parts: S) -> String where S.Element == String {
        let tail = parts.joined(separator: "/")
        if tail.isEmpty { return root }
        return root == "/" ? "/" + tail : root + "/" + tail
    }

    /// The trailing slash prevents a false match of "/proj-evil" against "/proj".
    private static func isInside(_ path: String, root: String) -> Bool {
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func lexists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
