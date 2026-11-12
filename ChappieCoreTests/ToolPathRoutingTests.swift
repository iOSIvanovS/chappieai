// ToolPathRoutingTests.swift
// ChappieCoreTests
//
// How a path and the `project` argument meet in the real entry point (authorize + file system).
// Regression: project "Chappie" contains a folder "Chappie/"; the old code stripped the leading
// "Chappie/" and silently redirected the call to the project root.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Tool path routing — project argument and same-named folder")
struct ToolPathRoutingTests {

    private struct Fixture {
        let service: ToolExecutionService
        let rootA: URL
        let rootB: URL
    }

    /// Two projects: "Chappie" (with an inner folder "Chappie/") and "Other".
    private func makeFixture(projects: Int) async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
        let rootA = base.appendingPathComponent("a")
        let rootB = base.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: rootA.appendingPathComponent("Chappie"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try "root-file".write(to: rootA.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try "inner-file".write(to: rootA.appendingPathComponent("Chappie/x.txt"), atomically: true, encoding: .utf8)

        var workspaces: [(name: String, url: URL)] = [(name: "Chappie", url: rootA)]
        var infos = [ActiveMemoryContext.ProjectInfo(id: UUID(), name: "Chappie")]
        if projects > 1 {
            workspaces.append((name: "Other", url: rootB))
            infos.append(ActiveMemoryContext.ProjectInfo(id: UUID(), name: "Other"))
        }
        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaces: workspaces),
            memoryManager: MemoryManager(workspaceURL: rootA),
            socketPath: "/tmp/chappie-routing-tests-nonexistent.sock"
        )
        let settings = ProjectSettings(agentRole: .executor, isProgrammingProject: true, devEnvironment: .xcode)
        await service.setMemoryContextAndSettings(
            context: ActiveMemoryContext(threadId: UUID(), projects: infos, threadTerminalAccess: .none),
            settings: Dictionary(uniqueKeysWithValues: infos.map { ($0.id, settings) })
        )
        return Fixture(service: service, rootA: rootA, rootB: rootB)
    }

    private func call(_ service: ToolExecutionService, _ tool: String, _ arguments: String) async -> String {
        await service.execute(call: AIToolCall(id: "t", type: "function", function: AIToolCallFunction(name: tool, arguments: arguments)))
    }

    @Test("Explicit project: 'Chappie/x.txt' is the inner folder, 'x.txt' is the root")
    func explicitProjectKeepsInnerFolder() async throws {
        let fixture = try await makeFixture(projects: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootA.deletingLastPathComponent()) }

        #expect(await call(fixture.service, "read_file", #"{"path":"Chappie/x.txt","project":"Chappie"}"#).contains("inner-file"))
        #expect(await call(fixture.service, "read_file", #"{"path":"x.txt","project":"Chappie"}"#).contains("root-file"))
    }

    @Test("Single project: the same rule — nothing is stripped")
    func singleProjectKeepsInnerFolder() async throws {
        let fixture = try await makeFixture(projects: 1)
        defer { try? FileManager.default.removeItem(at: fixture.rootA.deletingLastPathComponent()) }

        #expect(await call(fixture.service, "read_file", #"{"path":"Chappie/x.txt"}"#).contains("inner-file"))
    }

    @Test("Several projects, no project argument: the name prefix routes and is removed")
    func prefixRoutesWithoutProject() async throws {
        let fixture = try await makeFixture(projects: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootA.deletingLastPathComponent()) }

        #expect(await call(fixture.service, "read_file", #"{"path":"Chappie/x.txt"}"#).contains("root-file"))
        #expect(await call(fixture.service, "read_file", #"{"path":"Chappie/Chappie/x.txt"}"#).contains("inner-file"))
    }

    @Test("write_file with an explicit project lands in the inner folder, not the root")
    func writeLandsInInnerFolder() async throws {
        let fixture = try await makeFixture(projects: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootA.deletingLastPathComponent()) }

        _ = await call(fixture.service, "write_file", #"{"path":"Chappie/new.txt","content":"c","project":"Chappie"}"#)
        #expect(FileManager.default.fileExists(atPath: fixture.rootA.appendingPathComponent("Chappie/new.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rootA.appendingPathComponent("new.txt").path))
    }
}
