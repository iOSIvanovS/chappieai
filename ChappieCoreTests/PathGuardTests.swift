// PathGuardTests.swift
// ChappieCoreTests
//
// Security tests for the project-containment guard: "..", absolute paths, symlink escapes,
// sibling-prefix folders, and parity of the two source copies (Core + MCP).

import Testing
import Foundation
@testable import ChappieCore

@Suite("PathGuard Tests")
struct PathGuardTests {

    // MARK: - Fixture

    /// Layout: <base>/proj (root), <base>/proj-evil (sibling), <base>/outside (secret).
    private struct Sandbox {
        let base: URL
        let root: URL
        let evil: URL
        let outside: URL

        init() throws {
            let fm = FileManager.default
            base = fm.temporaryDirectory.appendingPathComponent("PathGuard_\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("proj", isDirectory: true)
            evil = base.appendingPathComponent("proj-evil", isDirectory: true)
            outside = base.appendingPathComponent("outside", isDirectory: true)
            for dir in [root, evil, outside] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try "SECRET".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
            try "EVIL".write(to: evil.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
            try "ok".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        }

        func link(_ name: String, to target: URL) throws {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(name), withDestinationURL: target
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: - Plain relative paths

    @Test("Normal relative paths resolve inside the root")
    func normalPaths() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let existing = try PathGuard.resolve("a.txt", inRoot: box.root)
        #expect(existing.lastPathComponent == "a.txt")
        let future = try PathGuard.resolve("sub/dir/new.txt", inRoot: box.root)
        #expect(future.path.hasSuffix("/proj/sub/dir/new.txt"))
        _ = try PathGuard.resolve("", inRoot: box.root)
        _ = try PathGuard.resolve("./a.txt", inRoot: box.root)
    }

    @Test("🔒 '..' is rejected, even when it would stay inside")
    func dotDotRejected() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        for path in ["../outside/secret.txt", "a/../../outside/secret.txt", "sub/../a.txt", ".."] {
            #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve(path, inRoot: box.root) }
        }
    }

    @Test("🔒 Absolute paths are rejected")
    func absoluteRejected() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("/etc/hosts", inRoot: box.root) }
        // Even an absolute path that points inside the project is refused: tools take relative paths.
        let inside = box.root.appendingPathComponent("a.txt").path
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve(inside, inRoot: box.root) }
    }

    @Test("🔒 NUL byte is rejected")
    func nulRejected() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("a.txt\0.png", inRoot: box.root) }
    }

    // MARK: - Symlinks

    @Test("🔒 Symlink to an outside folder is blocked, for existing and new files")
    func symlinkDirectoryEscape() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("linkdir", to: box.outside)
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("linkdir/secret.txt", inRoot: box.root) }
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("linkdir/brand/new.txt", inRoot: box.root) }
    }

    @Test("🔒 Symlink to an outside file is blocked")
    func symlinkFileEscape() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("link.txt", to: box.outside.appendingPathComponent("secret.txt"))
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("link.txt", inRoot: box.root) }
    }

    @Test("🔒 Symlink into a sibling folder sharing the root's name prefix is blocked")
    func siblingPrefixBlocked() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("evil", to: box.evil)
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("evil/e.txt", inRoot: box.root) }
    }

    @Test("🔒 Dangling symlink is blocked")
    func danglingSymlink() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("ghost", to: box.base.appendingPathComponent("does-not-exist"))
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("ghost", inRoot: box.root) }
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("ghost/new.txt", inRoot: box.root) }
    }

    @Test("Symlink that stays inside the project is allowed")
    func symlinkInsideAllowed() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try FileManager.default.createDirectory(at: box.root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try "x".write(to: box.root.appendingPathComponent("real/f.txt"), atomically: true, encoding: .utf8)
        try box.link("alias", to: box.root.appendingPathComponent("real"))
        _ = try PathGuard.resolve("alias/f.txt", inRoot: box.root)
    }

    @Test("Root that itself lives behind a symlink still works")
    func rootBehindSymlink() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let alias = box.base.appendingPathComponent("rootalias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: box.root)
        let resolved = try PathGuard.resolve("a.txt", inRoot: alias)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("../outside", inRoot: alias) }
    }

    @Test("A symlink itself can be addressed (delete acts on the link, not its target)")
    func linkItselfForDelete() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("inner", to: box.root.appendingPathComponent("a.txt"))
        let url = try PathGuard.resolve("inner", inRoot: box.root)
        #expect(url.lastPathComponent == "inner")
    }

    // MARK: - Invalid roots

    @Test("🔒 The filesystem root '/' is refused as a project root (it would make every path 'inside')")
    func filesystemRootRefused() throws {
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("tmp/x.xcstrings", inRoot: URL(fileURLWithPath: "/")) }
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("etc/hosts", inRoot: URL(fileURLWithPath: "/")) }
    }

    @Test("isUsableRoot rejects '/', empty, relative, missing and NUL paths; accepts real folders and symlinked ones")
    func usableRoot() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        #expect(PathGuard.isUsableRoot(box.root.path))
        #expect(!PathGuard.isUsableRoot("/"))
        #expect(!PathGuard.isUsableRoot(""))
        #expect(!PathGuard.isUsableRoot("relative/dir"))
        #expect(!PathGuard.isUsableRoot(box.base.appendingPathComponent("missing").path))
        #expect(!PathGuard.isUsableRoot(box.root.path + "\0x"))

        // A symlink that resolves to "/" is as hollow as "/" itself.
        let toSlash = box.base.appendingPathComponent("slash")
        try FileManager.default.createSymbolicLink(at: toSlash, withDestinationURL: URL(fileURLWithPath: "/"))
        #expect(!PathGuard.isUsableRoot(toSlash.path))
        #expect(throws: PathGuard.Violation.self) { try PathGuard.resolve("etc/hosts", inRoot: toSlash) }

        let alias = box.base.appendingPathComponent("rootalias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: box.root)
        #expect(PathGuard.isUsableRoot(alias.path))
    }

    // MARK: - Absolute exception (attachments store)

    @Test("Absolute path is accepted only inside an allowed root")
    func absoluteAllowedRoot() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let allowed = box.root.appendingPathComponent("a.txt").path
        let url = try PathGuard.resolveAbsolute(allowed, allowedRoots: [box.root])
        #expect(url.lastPathComponent == "a.txt")
        #expect(throws: PathGuard.Violation.self) {
            try PathGuard.resolveAbsolute(box.outside.appendingPathComponent("secret.txt").path, allowedRoots: [box.root])
        }
        #expect(throws: PathGuard.Violation.self) {
            try PathGuard.resolveAbsolute(box.evil.appendingPathComponent("e.txt").path, allowedRoots: [box.root])
        }
        #expect(throws: PathGuard.Violation.self) {
            try PathGuard.resolveAbsolute(box.root.path + "/../outside/secret.txt", allowedRoots: [box.root])
        }
    }

    @Test("🔒 Symlink inside an allowed absolute root cannot escape")
    func absoluteRootSymlinkEscape() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("linkdir", to: box.outside)
        #expect(throws: PathGuard.Violation.self) {
            try PathGuard.resolveAbsolute(box.root.appendingPathComponent("linkdir/secret.txt").path, allowedRoots: [box.root])
        }
    }

    // MARK: - FileSystemManager integration

    @Test("🔒 FileSystemManager: read, write, delete and move through an escaping symlink are blocked")
    func managerBlocksSymlinkEscape() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("linkdir", to: box.outside)
        let manager = FileSystemManager(workspaceURL: box.root)

        await #expect(throws: (any Error).self) { try await manager.readFile(at: "linkdir/secret.txt") }
        await #expect(throws: (any Error).self) { try await manager.writeFile(at: "linkdir/planted.txt", content: "x") }
        await #expect(throws: (any Error).self) { try await manager.deleteFile(at: "linkdir/secret.txt") }
        await #expect(throws: (any Error).self) { try await manager.moveFile(from: "a.txt", to: "linkdir/a.txt") }
        #expect(!FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("planted.txt").path))
        #expect(FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("secret.txt").path))
    }

    @Test("🔒 FileSystemManager: search and listing skip symlinks leading outside")
    func managerSearchAndListSkipEscapes() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.link("leak.txt", to: box.outside.appendingPathComponent("secret.txt"))
        try "SECRET inside".write(to: box.root.appendingPathComponent("own.txt"), atomically: true, encoding: .utf8)
        let manager = FileSystemManager(workspaceURL: box.root)

        let found = try await manager.searchInProject(query: "SECRET", projectName: nil, filePattern: nil, contextLines: 0)
        #expect(found.contains("own.txt"))
        #expect(!found.contains("leak.txt"))

        let files = try await manager.listFiles()
        #expect(files.contains(where: { $0.hasSuffix("own.txt") }))
        #expect(!files.contains(where: { $0.hasSuffix("leak.txt") }))
    }

    @Test("FileSystemManager: ordinary operations still work on a root behind a symlink")
    func managerWorksBehindSymlinkedRoot() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let alias = box.base.appendingPathComponent("rootalias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: box.root)
        let manager = FileSystemManager(workspaceURL: alias)

        try await manager.writeFile(at: "sub/new.txt", content: "hi")
        #expect(try await manager.readFile(at: "sub/new.txt") == "hi")
        try await manager.moveFile(from: "sub/new.txt", to: "sub/moved.txt")
        try await manager.deleteFile(at: "sub/moved.txt")
    }

    // MARK: - Parity of the two copies

    @Test("Core and MCP copies of PathGuard.swift are identical")
    func copiesAreIdentical() throws {
        // #filePath = <repo>/ChappieCoreTests/PathGuardTests.swift
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let core = repo.appendingPathComponent("ChappieCore/Sources/ChappieCore/Services/FileSystemManager/PathGuard.swift")
        let mcp = repo.appendingPathComponent("ChappieMCP/Sources/ChappieMCP/Tools/PathGuard.swift")
        let coreText = try String(contentsOf: core, encoding: .utf8)
        let mcpText = try String(contentsOf: mcp, encoding: .utf8)
        #expect(coreText == mcpText, "PathGuard.swift copies drifted apart — copy the Core file over the MCP one")
    }
}
