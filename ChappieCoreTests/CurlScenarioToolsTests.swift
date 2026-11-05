// CurlScenarioToolsTests.swift
// ChappieCoreTests
//
// Scenario FILES: folder safety, save/replace/delete through the tools, reverse references.
// A real temp project folder is used; nothing touches the network.

import Testing
import Foundation
@testable import ChappieCore

private func tempProject() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func read(_ scenario: String, steps: String = #"[{"id":"s","method":"GET","path":"/x"}]"#, extras: String = "") -> String {
    #"{"name":"\#(scenario)","description":"does a thing",\#(extras)"steps":\#(steps)}"#
}

@Suite("Curl scenarios - folder safety")
struct CurlScenarioFolderTests {

    @Test("The folder must be given and stay inside the project")
    func folderRules() throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CurlScenarioStore.Failure.self) { try CurlScenarioStore(root: root, folder: "") }
        #expect(throws: CurlScenarioStore.Failure.self) { try CurlScenarioStore(root: root, folder: "../out") }
        #expect(throws: CurlScenarioStore.Failure.self) { try CurlScenarioStore(root: root, folder: "/tmp") }
        #expect(throws: CurlScenarioStore.Failure.self) { try CurlScenarioStore(root: root, folder: ".git/hooks") }
        #expect(throws: CurlScenarioStore.Failure.self) { try CurlScenarioStore(root: root, folder: "App.xcodeproj/x") }
        #expect(throws: CurlScenarioStore.Failure.self) { try CurlScenarioStore(root: root, folder: ".") }
        _ = try CurlScenarioStore(root: root, folder: "Scenarios")
        _ = try CurlScenarioStore(root: root, folder: ".chappie/scenarios")
        _ = try CurlScenarioStore(root: root, folder: "./Scenarios/")
    }

    @Test("A symlinked folder that leaves the project is refused")
    func symlinkEscape() throws {
        let root = try tempProject()
        let outside = try tempProject()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: outside)
        #expect(throws: CurlScenarioStore.Failure.self) { try CurlScenarioStore(root: root, folder: "Linked") }
    }

    @Test("File names cannot carry paths")
    func fileNames() throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CurlScenarioStore(root: root, folder: "Scenarios")
        #expect(throws: CurlScenarioStore.Failure.self) { try store.fileURL(for: "../evil") }
        #expect(throws: CurlScenarioStore.Failure.self) { try store.fileURL(for: "a/b") }
        #expect(throws: CurlScenarioStore.Failure.self) { try store.fileURL(for: "") }
        _ = try store.fileURL(for: "Авторизация")
    }
}

@Suite("Curl scenarios - save, info, delete")
struct CurlScenarioToolFlowTests {

    private func service(_ root: URL) async -> ToolExecutionService {
        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaceURL: root),
            memoryManager: MemoryManager(workspaceURL: root),
            socketPath: "/tmp/chappie-scenario-tests-nonexistent.sock")
        let info = ActiveMemoryContext.ProjectInfo(id: UUID(), name: "P")
        await service.setActiveMemoryContext(ActiveMemoryContext(
            threadId: UUID(), projects: [info], projectPathMap: ["P": root.path], curlEnabled: true))
        return service
    }

    private func call(_ service: ToolExecutionService, _ tool: String, _ args: [String: String]) async -> String {
        var all = args
        all["project"] = "P"
        let data = (try? JSONEncoder().encode(all)) ?? Data()
        return await service.executeCurlScenarioTool(name: tool, argsData: data)
    }

    @Test("Save writes a pretty file, replacing says so, and info lists it")
    func saveAndInfo() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await service(root)

        let first = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("ping")])
        #expect(first.contains("Saved scenario 'ping'"), "\(first)")
        let file = root.appendingPathComponent("Scenarios/ping.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\n") && text.hasSuffix("\n"))

        let second = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("ping")])
        #expect(second.contains("Replaced scenario 'ping'"), "\(second)")

        let list = await call(s, "curl_scenario_info", ["folder": "Scenarios"])
        #expect(list.contains("ping") && list.contains("does a thing"), "\(list)")
        let one = await call(s, "curl_scenario_info", ["folder": "Scenarios", "name": "ping"])
        #expect(one.contains("\"steps\""), "\(one)")
    }

    @Test("An invalid scenario is not written and every problem is listed")
    func rejectsInvalid() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await service(root)
        let bad = #"{"name":"bad","description":"d","steps":[{"id":"s","method":"POST","path":"x","extract":{"v":"json:a"}},{"id":"t","method":"GET","path":"/{{var:nope}}"}]}"#
        let out = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": bad])
        #expect(out.contains("not saved"))
        #expect(out.contains("mutates") && out.contains("must start with '/'") && out.contains("{{var:nope}}"), "\(out)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Scenarios/bad.json").path))
    }

    @Test("The name argument must match the scenario's own name")
    func nameMismatch() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await service(root)
        let out = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("one"), "name": "two"])
        #expect(out.contains("❌"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Scenarios").path))
    }

    @Test("Delete is refused while another scenario calls it, then allowed")
    func deleteProtection() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await service(root)
        _ = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("base")])
        let caller = read("top", steps: #"[{"id":"k","call":"base"}]"#)
        let saved = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": caller])
        #expect(saved.contains("Saved"), "\(saved)")

        let refused = await call(s, "curl_scenario_delete", ["folder": "Scenarios", "name": "base"])
        #expect(refused.contains("still called by: top"), "\(refused)")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Scenarios/base.json").path))

        #expect(await call(s, "curl_scenario_delete", ["folder": "Scenarios", "name": "top"]).contains("Deleted"))
        #expect(await call(s, "curl_scenario_delete", ["folder": "Scenarios", "name": "base"]).contains("Deleted"))
        #expect(await call(s, "curl_scenario_delete", ["folder": "Scenarios", "name": "base"]).contains("does not exist"))
    }

    @Test("Changing a callee's contract warns about the scenarios that call it")
    func contractBreakWarning() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await service(root)
        _ = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("base")])
        _ = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("top", steps: #"[{"id":"k","call":"base"}]"#)])
        let changed = read("base", extras: #""inputs":[{"name":"must"}],"#)
        let out = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": changed])
        #expect(out.contains("Replaced") && out.contains("no longer validate") && out.contains("top"), "\(out)")
    }

    @Test("Saving a scenario that would close a cycle is refused")
    func cycleOnSave() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await service(root)
        _ = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("a")])
        _ = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": read("b", steps: #"[{"id":"k","call":"a"}]"#)])
        let closing = read("a", steps: #"[{"id":"k","call":"b"}]"#)
        let out = await call(s, "curl_scenario_save", ["folder": "Scenarios", "scenario": closing])
        #expect(out.contains("cycle"), "\(out)")
    }

    @Test("A missing folder argument and an unresolved project are explained")
    func missingArguments() async throws {
        let root = try tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = await service(root)
        #expect(await call(s, "curl_scenario_info", [:]).contains("folder"))
        let data = try JSONEncoder().encode(["project": "Ghost", "folder": "Scenarios"])
        #expect(await s.executeCurlScenarioTool(name: "curl_scenario_info", argsData: data).contains("not resolved"))
    }
}
