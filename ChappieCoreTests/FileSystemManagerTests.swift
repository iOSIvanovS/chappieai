// FileSystemManagerTests.swift
// ChappieCoreTests
//
// Unit tests for FileSystemManager.
//
// PRIORITY:
// Security first. Path Traversal (CWE-22) is a critical vulnerability —
// if the guard breaks, the AI can read/write system files.
// Security tests are marked explicitly and must pass on every refactor.
//
// ISOLATION:
// Each test runs in a temp directory — real project files are never touched.
//
// NOTE on listFiles():
// FileSystemManager.listFiles() is synchronous (throws, not async throws).
// We compare via hasSuffix to be resilient to /private/tmp vs /tmp symlink differences.

import Testing
import Foundation
@testable import ChappieCore

@Suite("FileSystemManager Tests")
struct FileSystemManagerTests {

    // MARK: - Helpers

    private func makeManager() throws -> (FileSystemManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSMTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manager = FileSystemManager(workspaceURL: tempDir)
        return (manager, tempDir)
    }

    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSMTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Read

    @Test("Read existing file")
    func readExistingFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        let fileURL = workspace.appendingPathComponent("test.txt")
        try "Hello, Chappie!".write(to: fileURL, atomically: true, encoding: .utf8)

        let content = try await manager.readFile(at: "test.txt")
        #expect(content == "Hello, Chappie!")
    }

    @Test("Read missing file throws")
    func readMissingFileThrows() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "nonexistent_file_xyz.txt")
        }
    }

    // MARK: - Write

    @Test("Write new file")
    func writeNewFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "new_file.swift", content: "import Foundation")

        let fileURL = workspace.appendingPathComponent("new_file.swift")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(content == "import Foundation")
    }

    @Test("Write to subdirectory creates intermediate folders")
    func writeToSubdirectoryCreatesDirectories() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "Views/Chat/ChatView.swift", content: "// ChatView")

        let fileURL = workspace.appendingPathComponent("Views/Chat/ChatView.swift")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Overwrite existing file")
    func overwriteExistingFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "file.txt", content: "old content")
        try await manager.writeFile(at: "file.txt", content: "new content")

        let content = try await manager.readFile(at: "file.txt")
        #expect(content == "new content")
    }

    // MARK: - Delete

    @Test("Delete existing file")
    func deleteExistingFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "to_delete.txt", content: "bye")

        let fileURL = workspace.appendingPathComponent("to_delete.txt")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try await manager.deleteFile(at: "to_delete.txt")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Delete missing file throws")
    func deleteMissingFileThrows() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.deleteFile(at: "ghost_file.txt")
        }
    }

    // MARK: - List files

    @Test("listFiles returns all files")
    func listFilesReturnsAllFiles() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "a.swift", content: "")
        try await manager.writeFile(at: "b.swift", content: "")
        try await manager.writeFile(at: "sub/c.swift", content: "")

        let files = try await manager.listFiles()

        #expect(files.contains(where: { $0.hasSuffix("a.swift") }), "a.swift must be listed")
        #expect(files.contains(where: { $0.hasSuffix("b.swift") }), "b.swift must be listed")
        #expect(files.contains(where: { $0.hasSuffix("c.swift") }), "sub/c.swift must be listed")
    }

    // MARK: - Multi-workspace (B-01)

    @Test("Multi-workspace: listFiles prefixes paths with project name")
    func multiWorkspaceListFilesHasPrefixes() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer { cleanup(dir1); cleanup(dir2) }

        // Seed files directly into each workspace dir.
        try "".write(to: dir1.appendingPathComponent("alpha.swift"), atomically: true, encoding: .utf8)
        try "".write(to: dir2.appendingPathComponent("beta.swift"), atomically: true, encoding: .utf8)

        let manager = FileSystemManager(workspaces: [
            (name: "ProjectA", url: dir1),
            (name: "ProjectB", url: dir2)
        ])

        let files = try await manager.listFiles()

        #expect(files.contains(where: { $0.hasPrefix("ProjectA/") && $0.hasSuffix("alpha.swift") }),
                "ProjectA/alpha.swift must be listed")
        #expect(files.contains(where: { $0.hasPrefix("ProjectB/") && $0.hasSuffix("beta.swift") }),
                "ProjectB/beta.swift must be listed")
    }

    @Test("Multi-workspace: readFile routes by project prefix")
    func multiWorkspaceReadFileRoutes() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer { cleanup(dir1); cleanup(dir2) }

        try "content-A".write(to: dir1.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "content-B".write(to: dir2.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let manager = FileSystemManager(workspaces: [
            (name: "Alpha", url: dir1),
            (name: "Beta", url: dir2)
        ])

        let contentA = try await manager.readFile(at: "Alpha/file.txt")
        let contentB = try await manager.readFile(at: "Beta/file.txt")

        #expect(contentA == "content-A")
        #expect(contentB == "content-B")
    }

    @Test("Multi-workspace: writeFile routes by project prefix")
    func multiWorkspaceWriteFileRoutes() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer { cleanup(dir1); cleanup(dir2) }

        let manager = FileSystemManager(workspaces: [
            (name: "Alpha", url: dir1),
            (name: "Beta", url: dir2)
        ])

        try await manager.writeFile(at: "Alpha/out.txt", content: "hello from alpha")
        try await manager.writeFile(at: "Beta/out.txt", content: "hello from beta")

        let readA = try String(contentsOf: dir1.appendingPathComponent("out.txt"), encoding: .utf8)
        let readB = try String(contentsOf: dir2.appendingPathComponent("out.txt"), encoding: .utf8)

        #expect(readA == "hello from alpha")
        #expect(readB == "hello from beta")
    }

    @Test("Multi-workspace: unknown prefix throws")
    func multiWorkspaceUnknownPrefixThrows() async throws {
        let dir1 = try makeTempDir()
        defer { cleanup(dir1) }

        let manager = FileSystemManager(workspaces: [
            (name: "Alpha", url: dir1)
        ])

        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "Unknown/file.txt")
        }
    }

    // MARK: - Security (Path Traversal)

    @Test("🔒 Path traversal via ../ is blocked")
    func pathTraversalUpDirectoryBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "../../etc/passwd")
        }
    }

    @Test("🔒 Absolute path is blocked")
    func absolutePathBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "/etc/hosts")
        }
    }

    @Test("🔒 Write outside workspace is blocked")
    func writeOutsideWorkspaceBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.writeFile(at: "../evil_file.txt", content: "hacked")
        }
    }

    @Test("🔒 Delete outside workspace is blocked")
    func deleteOutsideWorkspaceBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.deleteFile(at: "../../important_file.txt")
        }
    }

    @Test("🔒 Multi-workspace: path traversal across projects is blocked")
    func multiWorkspacePathTraversalBlocked() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer { cleanup(dir1); cleanup(dir2) }

        // Plant a file in dir2 that shouldn't be reachable from Alpha workspace.
        try "secret".write(to: dir2.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        let manager = FileSystemManager(workspaces: [
            (name: "Alpha", url: dir1),
            (name: "Beta", url: dir2)
        ])

        // Attempt to reach Beta's file from Alpha's workspace context via traversal.
        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "Alpha/../../\(dir2.lastPathComponent)/secret.txt")
        }
    }
}
