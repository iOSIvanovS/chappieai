// ThreadIsolationTests.swift
// ChappieCoreTests / M-09
//
// End-to-end verification of zero state leakage in the V2 thread isolation architecture.
//
// WHAT WE TEST:
//   1. SystemPromptBuilder — correct section injection, empty sections omitted,
//      per-project memory isolation, tool permissions derived from project settings
//   2. ToolAccessController — git_diff iron prohibition, tool gating by permission level,
//      always-on tools always pass, unknown tools pass (forward-compat)
//   3. State isolation — two PromptContexts built independently share no state,
//      project memory from thread A does not appear in thread B's prompt

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Helpers

private func makeEntry(key: String, type: String = "fact", value: String = "test") -> MemoryEntry {
    MemoryEntry(key: key, type: type, jsonString: "{\"value\": \"\(value)\"}")
}

// MARK: - SystemPromptBuilder Tests

@Suite("SystemPromptBuilder — V2 prompt assembly")
struct SystemPromptBuilderTests {

    private let persona = "You are Chappie."

    private func makeBuilder() -> New.SystemPromptBuilder {
        New.SystemPromptBuilder(personaBlock: persona)
    }

    // MARK: - Basic structure

    @Test("Empty context returns only persona block")
    func emptyContextReturnsOnlyPersona() {
        let prompt = makeBuilder().build(context: .empty)
        #expect(prompt == persona)
    }

    @Test("userName is injected when present")
    func userNameIsInjected() {
        let ctx = New.PromptContext(userName: "Sergey")
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("The user's name is Sergey."))
    }

    @Test("Empty userName is NOT injected")
    func emptyUserNameIsNotInjected() {
        let ctx = New.PromptContext(userName: "")
        let prompt = makeBuilder().build(context: ctx)
        #expect(!prompt.contains("The user's name is"))
    }

    @Test("nil userName is NOT injected")
    func nilUserNameIsNotInjected() {
        let ctx = New.PromptContext(userName: nil)
        let prompt = makeBuilder().build(context: ctx)
        #expect(!prompt.contains("The user's name is"))
    }

    // MARK: - Memory sections

    @Test("Global memory section appears when non-empty")
    func globalMemorySectionAppearsWhenNonEmpty() {
        let ctx = New.PromptContext(globalMemory: [makeEntry(key: "test_rule", type: "rule")])
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("## Global Memory"))
        #expect(prompt.contains("test_rule"))
    }

    @Test("Global memory section is OMITTED when empty")
    func globalMemorySectionOmittedWhenEmpty() {
        let prompt = makeBuilder().build(context: New.PromptContext(globalMemory: []))
        #expect(!prompt.contains("## Global Memory"))
    }

    @Test("Thread memory section appears when non-empty")
    func threadMemorySectionAppearsWhenNonEmpty() {
        let ctx = New.PromptContext(threadMemory: [makeEntry(key: "task_context")])
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("## Thread Context"))
        #expect(prompt.contains("task_context"))
    }

    @Test("Thread memory section is OMITTED when empty")
    func threadMemorySectionOmittedWhenEmpty() {
        let prompt = makeBuilder().build(context: New.PromptContext(threadMemory: []))
        #expect(!prompt.contains("## Thread Context"))
    }

    // MARK: - Project isolation (KEY: no cross-thread leakage)

    @Test("Project memory from project A does NOT appear in project B memory block")
    func projectMemoryIsIsolatedBetweenProjects() {
        let builder = makeBuilder()

        let ctxA = New.PromptContext.ProjectContext(
            name: "ProjectA",
            settings: ProjectSettings(agentRole: .executor),
            memory: [makeEntry(key: "secret_a", value: "only for project A")]
        )
        let ctxB = New.PromptContext.ProjectContext(
            name: "ProjectB",
            settings: ProjectSettings(agentRole: .executor),
            memory: [makeEntry(key: "secret_b", value: "only for project B")]
        )

        let prompt = builder.build(context: New.PromptContext(projects: [ctxA, ctxB]))

        // Both project settings blocks present
        #expect(prompt.contains("Project Settings: ProjectA"))
        #expect(prompt.contains("Project Settings: ProjectB"))

        // Both keys are present somewhere in the prompt
        #expect(prompt.contains("secret_a"))
        #expect(prompt.contains("secret_b"))

        // Verify memory sections are scoped — parse line by line
        let lines = prompt.components(separatedBy: "\n")
        var inProjectAMemory = false
        var inProjectBMemory = false
        var aSeesB = false
        var bSeesA = false

        for line in lines {
            if line.contains("## Project Memory: ProjectA") {
                inProjectAMemory = true
                inProjectBMemory = false
            }
            if line.contains("## Project Memory: ProjectB") {
                inProjectBMemory = true
                inProjectAMemory = false
            }
            // Reset on next project settings block
            if line.contains("## Project Settings:") {
                inProjectAMemory = false
                inProjectBMemory = false
            }
            if inProjectAMemory && line.contains("secret_b") { aSeesB = true }
            if inProjectBMemory && line.contains("secret_a") { bSeesA = true }
        }

        #expect(!aSeesB, "Project A's memory block must NOT contain Project B's keys")
        #expect(!bSeesA, "Project B's memory block must NOT contain Project A's keys")
    }

    @Test("No projects attached → no project settings block in prompt")
    func noProjectsProducesNoProjectBlock() {
        let ctx = New.PromptContext(userName: "Sergey")
        let prompt = makeBuilder().build(context: ctx)
        #expect(!prompt.contains("## Project Settings"))
        #expect(!prompt.contains("## Project Memory"))
    }

    @Test("Project with empty memory → no project memory block")
    func projectWithEmptyMemoryHasNoMemoryBlock() {
        let projectCtx = New.PromptContext.ProjectContext(
            name: "EmptyProject",
            settings: ProjectSettings(agentRole: .advisor),
            memory: []
        )
        let prompt = makeBuilder().build(context: New.PromptContext(projects: [projectCtx]))
        #expect(prompt.contains("Project Settings: EmptyProject"))
        #expect(!prompt.contains("## Project Memory: EmptyProject"))
    }

    // MARK: - Two independent contexts share no state (zero leakage)

    @Test("Two independent PromptContexts produce independent prompts")
    func twoContextsAreCompletelyIndependent() {
        let builder = makeBuilder()

        let ctx1 = New.PromptContext(
            userName: "Alice",
            threadMemory: [makeEntry(key: "thread1_key", value: "thread 1 data")]
        )
        let ctx2 = New.PromptContext(
            userName: "Bob",
            threadMemory: [makeEntry(key: "thread2_key", value: "thread 2 data")]
        )

        let prompt1 = builder.build(context: ctx1)
        let prompt2 = builder.build(context: ctx2)

        #expect(!prompt1.contains("thread2_key"), "Thread 1 prompt must not contain thread 2 memory")
        #expect(!prompt1.contains("Bob"), "Thread 1 prompt must not contain thread 2 userName")
        #expect(!prompt2.contains("thread1_key"), "Thread 2 prompt must not contain thread 1 memory")
        #expect(!prompt2.contains("Alice"), "Thread 2 prompt must not contain thread 1 userName")
    }

    // MARK: - Tool permissions

    @Test("No projects → readOnly permissions (safe fallback)")
    func noProjectsGivesReadOnlyPermissions() {
        let perms = makeBuilder().toolPermissions(for: .empty)
        #expect(perms.canReadFiles == true)
        #expect(perms.canWriteFiles == false)
        #expect(perms.gitLevel == .none)
        #expect(perms.canRunTests == false)
    }

    @Test("Advisor role → read files only, no write/git/tests")
    func advisorRoleGivesReadOnlyPermissions() {
        let ctx = New.PromptContext(projects: [
            .init(name: "P", settings: ProjectSettings(agentRole: .advisor), memory: [])
        ])
        let perms = makeBuilder().toolPermissions(for: ctx)
        #expect(perms.canReadFiles == true)
        #expect(perms.canWriteFiles == false)
        #expect(perms.gitLevel == .none)
        #expect(perms.canRunTests == false)
    }

    @Test("Executor with full git → full git permissions")
    func executorWithFullGitGivesFullGitPermissions() {
        let settings = ProjectSettings(
            agentRole: .executor,
            isProgrammingProject: true,
            gitAccess: .full
        )
        let ctx = New.PromptContext(projects: [
            .init(name: "Dev", settings: settings, memory: [])
        ])
        let perms = makeBuilder().toolPermissions(for: ctx)
        #expect(perms.canWriteFiles == true)
        #expect(perms.gitLevel == .full)
    }

    @Test("Two projects: most permissive git level wins across projects")
    func mostPermissiveGitLevelWinsAcrossProjects() {
        let settingsA = ProjectSettings(
            agentRole: .executor,
            isProgrammingProject: true,
            gitAccess: .statusOnly
        )
        let settingsB = ProjectSettings(
            agentRole: .executor,
            isProgrammingProject: true,
            gitAccess: .full
        )
        let ctx = New.PromptContext(projects: [
            .init(name: "A", settings: settingsA, memory: []),
            .init(name: "B", settings: settingsB, memory: [])
        ])
        let perms = makeBuilder().toolPermissions(for: ctx)
        #expect(perms.gitLevel == .full, "Full git from project B must win over statusOnly from A")
    }
}

// MARK: - ToolAccessController Tests

@Suite("ToolAccessController — V2 tool gating")
struct ToolAccessControllerTests {

    // Full permissions — used to test iron prohibitions that bypass everything.
    private let maxPerms = New.ToolPermissions(
        canReadFiles: true,
        canWriteFiles: true,
        gitLevel: .full,
        canRunTests: true,
        canWriteTests: true,
        canReadBuildLog: true
    )

    // MARK: - Iron prohibition

    @Test("git_diff is ALWAYS denied — iron prohibition, no override")
    func gitDiffIsAlwaysDenied() {
        let result = New.ToolAccessController.check(toolName: "git_diff", permissions: maxPerms)
        #expect(!result.isAllowed, "git_diff must be denied regardless of permissions")
        if case .denied(let reason) = result {
            #expect(reason.contains("FORBIDDEN"), "Denial reason must mention FORBIDDEN")
        }
    }

    @Test("git_diff denial JSON is valid JSON with correct fields")
    func gitDiffDenialJSONIsWellFormed() {
        let result = New.ToolAccessController.check(toolName: "git_diff", permissions: maxPerms)
        let json = result.denialJSON(toolName: "git_diff")
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil, "Denial JSON must be valid JSON")
        #expect(parsed?["error"] as? String == "tool_access_denied")
        #expect(parsed?["tool"] as? String == "git_diff")
    }

    // MARK: - Always-on tools

    @Test("Memory tools always allowed regardless of permissions")
    func memoryToolsAlwaysAllowed() {
        for tool in ["memorize", "recall", "search_memory", "delete_memory"] {
            let result = New.ToolAccessController.check(toolName: tool, permissions: .none)
            #expect(result.isAllowed, "\(tool) must always be allowed")
        }
    }

    @Test("web_fetch always allowed regardless of permissions")
    func webFetchAlwaysAllowed() {
        #expect(New.ToolAccessController.check(toolName: "web_fetch", permissions: .none).isAllowed)
    }

    @Test("Thread project management tools always allowed")
    func threadProjectToolsAlwaysAllowed() {
        for tool in ["add_project_to_thread", "remove_project_from_thread", "list_thread_projects"] {
            let result = New.ToolAccessController.check(toolName: tool, permissions: .none)
            #expect(result.isAllowed, "\(tool) must always be allowed")
        }
    }

    // MARK: - Read tools

    @Test("list_files denied when canReadFiles = false")
    func listFilesDeniedWithoutReadAccess() {
        #expect(!New.ToolAccessController.check(toolName: "list_files", permissions: .none).isAllowed)
    }

    @Test("read_file denied when canReadFiles = false")
    func readFileDeniedWithoutReadAccess() {
        #expect(!New.ToolAccessController.check(toolName: "read_file", permissions: .none).isAllowed)
    }

    @Test("list_files allowed when canReadFiles = true")
    func listFilesAllowedWithReadAccess() {
        #expect(New.ToolAccessController.check(toolName: "list_files", permissions: .readOnly).isAllowed)
    }

    @Test("read_file allowed when canReadFiles = true")
    func readFileAllowedWithReadAccess() {
        #expect(New.ToolAccessController.check(toolName: "read_file", permissions: .readOnly).isAllowed)
    }

    // MARK: - Write tools

    @Test("write_file denied when canWriteFiles = false")
    func writeFileDeniedWithoutWriteAccess() {
        #expect(!New.ToolAccessController.check(toolName: "write_file", permissions: .readOnly).isAllowed)
    }

    @Test("delete_file denied when canWriteFiles = false")
    func deleteFileDeniedWithoutWriteAccess() {
        #expect(!New.ToolAccessController.check(toolName: "delete_file", permissions: .readOnly).isAllowed)
    }

    @Test("write_file allowed when canWriteFiles = true")
    func writeFileAllowedWithWriteAccess() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: true,
            gitLevel: .none, canRunTests: false, canWriteTests: false, canReadBuildLog: false
        )
        #expect(New.ToolAccessController.check(toolName: "write_file", permissions: perms).isAllowed)
    }

    // MARK: - Git tools by level

    @Test("git_status denied when gitLevel = none")
    func gitStatusDeniedWithNoGit() {
        #expect(!New.ToolAccessController.check(toolName: "git_status", permissions: .none).isAllowed)
    }

    @Test("git_status allowed when gitLevel = statusOnly")
    func gitStatusAllowedWithStatusOnly() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: false,
            gitLevel: .statusOnly, canRunTests: false, canWriteTests: false, canReadBuildLog: false
        )
        #expect(New.ToolAccessController.check(toolName: "git_status", permissions: perms).isAllowed)
    }

    @Test("git_commit denied when gitLevel = statusOnly")
    func gitCommitDeniedWithStatusOnly() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: true,
            gitLevel: .statusOnly, canRunTests: false, canWriteTests: false, canReadBuildLog: false
        )
        #expect(!New.ToolAccessController.check(toolName: "git_commit", permissions: perms).isAllowed)
    }

    @Test("git_commit allowed when gitLevel = write")
    func gitCommitAllowedWithWriteLevel() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: true,
            gitLevel: .write, canRunTests: false, canWriteTests: false, canReadBuildLog: false
        )
        #expect(New.ToolAccessController.check(toolName: "git_commit", permissions: perms).isAllowed)
    }

    @Test("git_revert denied when gitLevel = write (requires full)")
    func gitRevertDeniedWithWriteLevel() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: true,
            gitLevel: .write, canRunTests: false, canWriteTests: false, canReadBuildLog: false
        )
        #expect(!New.ToolAccessController.check(toolName: "git_revert", permissions: perms).isAllowed)
    }

    @Test("git_revert allowed when gitLevel = full")
    func gitRevertAllowedWithFullLevel() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: true,
            gitLevel: .full, canRunTests: false, canWriteTests: false, canReadBuildLog: false
        )
        #expect(New.ToolAccessController.check(toolName: "git_revert", permissions: perms).isAllowed)
    }

    // MARK: - Build/test tools

    @Test("build_project denied when canRunTests = false")
    func buildProjectDeniedWithoutTestAccess() {
        #expect(!New.ToolAccessController.check(toolName: "build_project", permissions: .none).isAllowed)
    }

    @Test("run_tests denied when canRunTests = false")
    func runTestsDeniedWithoutTestAccess() {
        #expect(!New.ToolAccessController.check(toolName: "run_tests", permissions: .none).isAllowed)
    }

    @Test("build_project allowed when canRunTests = true")
    func buildProjectAllowedWithTestAccess() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: true,
            gitLevel: .full, canRunTests: true, canWriteTests: false, canReadBuildLog: true
        )
        #expect(New.ToolAccessController.check(toolName: "build_project", permissions: perms).isAllowed)
    }

    @Test("read_build_log denied when canReadBuildLog = false")
    func readBuildLogDeniedWithoutAccess() {
        #expect(!New.ToolAccessController.check(toolName: "read_build_log", permissions: .none).isAllowed)
    }

    @Test("read_build_log allowed when canReadBuildLog = true")
    func readBuildLogAllowedWithAccess() {
        let perms = New.ToolPermissions(
            canReadFiles: true, canWriteFiles: false,
            gitLevel: .none, canRunTests: false, canWriteTests: false, canReadBuildLog: true
        )
        #expect(New.ToolAccessController.check(toolName: "read_build_log", permissions: perms).isAllowed)
    }

    // MARK: - Forward compatibility

    @Test("Unknown tool is allowed by default (forward-compatible)")
    func unknownToolAllowedByDefault() {
        // New tools added in the future must not be silently blocked.
        let result = New.ToolAccessController.check(
            toolName: "some_future_tool_xyz",
            permissions: .none
        )
        #expect(result.isAllowed, "Unknown tools must pass through — forward-compat rule")
    }

    // MARK: - AccessResult helpers

    @Test("allowed result: isAllowed = true")
    func allowedResultIsAllowed() {
        #expect(New.AccessResult.allowed.isAllowed == true)
    }

    @Test("denied result: isAllowed = false")
    func deniedResultIsNotAllowed() {
        #expect(New.AccessResult.denied(reason: "test").isAllowed == false)
    }

    @Test("denialJSON on .allowed returns empty object {}")
    func denialJSONOnAllowedReturnsEmptyObject() {
        #expect(New.AccessResult.allowed.denialJSON(toolName: "test_tool") == "{}")
    }
}
