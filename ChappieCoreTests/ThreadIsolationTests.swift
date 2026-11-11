// ThreadIsolationTests.swift
// ChappieCoreTests / M-09
//
// End-to-end verification of zero state leakage in the V2 thread isolation architecture.
//
// WHAT WE TEST:
//   1. SystemPromptBuilder — correct section injection, empty sections omitted,
//      per-project memory isolation, tool permissions derived from project settings
//   2. State isolation — two PromptContexts built independently share no state,
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

    private func makeBuilder() -> SystemPromptBuilder {
        SystemPromptBuilder(personaBlock: persona)
    }

    /// Creates a project context with executor role + programming project enabled by default,
    /// then overlays the provided settings on top (terminalAccess, etc.).
    private func makeProject(settings: ProjectSettings) -> PromptContext.ProjectContext {
        var base = ProjectSettings(agentRole: .executor, isProgrammingProject: true)
        base.terminalAccess = settings.terminalAccess
        return PromptContext.ProjectContext(name: "TestProject", settings: base, memory: [])
    }

    /// Extracts the project settings block from the full prompt for a given project name.
    private func extractProjectSection(from prompt: String, projectName: String) -> String {
        let header = "## Project Settings: \(projectName)"
        let lines = prompt.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.hasPrefix(header) }) else { return "" }
        // collect lines until the next "##" section or end
        var result: [String] = []
        for line in lines[startIdx...] {
            if result.isEmpty || !line.hasPrefix("##") || line.hasPrefix(header) {
                result.append(line)
            } else {
                break
            }
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Basic structure

    @Test("Empty context is exactly the persona block")
    func emptyContextIsPersonaOnly() {
        let prompt = makeBuilder().build(context: .empty)
        #expect(prompt == persona)
    }

    @Test("userName is injected when present")
    func userNameIsInjected() {
        let ctx = PromptContext(userName: "Sergey")
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("The user's name is Sergey."))
    }

    @Test("Empty userName is NOT injected")
    func emptyUserNameIsNotInjected() {
        let ctx = PromptContext(userName: "")
        let prompt = makeBuilder().build(context: ctx)
        #expect(!prompt.contains("The user's name is"))
    }

    @Test("nil userName is NOT injected")
    func nilUserNameIsNotInjected() {
        let ctx = PromptContext(userName: nil)
        let prompt = makeBuilder().build(context: ctx)
        #expect(!prompt.contains("The user's name is"))
    }

    // MARK: - Memory sections

    @Test("Global memory section appears when non-empty")
    func globalMemorySectionAppearsWhenNonEmpty() {
        let ctx = PromptContext(globalMemory: [makeEntry(key: "test_rule", type: "rule")])
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("## Global Memory"))
        #expect(prompt.contains("test_rule"))
    }

    @Test("Global memory section is OMITTED when empty")
    func globalMemorySectionOmittedWhenEmpty() {
        let prompt = makeBuilder().build(context: PromptContext(globalMemory: []))
        #expect(!prompt.contains("## Global Memory"))
    }

    @Test("Thread memory section appears when non-empty")
    func threadMemorySectionAppearsWhenNonEmpty() {
        let ctx = PromptContext(threadMemory: [makeEntry(key: "task_context")])
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("## Thread Memory"))
        #expect(prompt.contains("task_context"))
    }

    @Test("Thread memory section is OMITTED when empty")
    func threadMemorySectionOmittedWhenEmpty() {
        let prompt = makeBuilder().build(context: PromptContext(threadMemory: []))
        #expect(!prompt.contains("## Thread Memory"))
    }

    @Test("Block order: user, project settings, global, thread, project memory; no wrapper header")
    func blockOrderAndNoWrapper() throws {
        let project = PromptContext.ProjectContext(
            name: "P",
            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true),
            memory: [makeEntry(key: "proj_key")],
            absolutePath: "/tmp/p"
        )
        let ctx = PromptContext(
            userName: "Ann",
            globalMemory: [makeEntry(key: "glob_key")],
            threadMemory: [makeEntry(key: "thr_key")],
            projects: [project]
        )
        let prompt = makeBuilder().build(context: ctx)

        #expect(!prompt.contains("Memory Context"))
        #expect(prompt.hasPrefix(persona + "\n\n---\n\n"))

        let markers = ["The user's name is Ann.", "## Project Settings: P", "## Global Memory",
                       "## Thread Memory", "## Project Memory: P"]
        var last = prompt.startIndex
        for marker in markers {
            let range = try #require(prompt.range(of: marker))
            #expect(range.lowerBound >= last, "\(marker) is out of order")
            last = range.lowerBound
        }
    }

    // MARK: - Project isolation (KEY: no cross-thread leakage)

    @Test("Project memory from project A does NOT appear in project B memory block")
    func projectMemoryIsIsolatedBetweenProjects() {
        let builder = makeBuilder()

        let ctxA = PromptContext.ProjectContext(
            name: "ProjectA",
            settings: ProjectSettings(agentRole: .executor),
            memory: [makeEntry(key: "secret_a", value: "only for project A")]
        )
        let ctxB = PromptContext.ProjectContext(
            name: "ProjectB",
            settings: ProjectSettings(agentRole: .executor),
            memory: [makeEntry(key: "secret_b", value: "only for project B")]
        )

        let prompt = builder.build(context: PromptContext(projects: [ctxA, ctxB]))

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
        let ctx = PromptContext(userName: "Sergey")
        let prompt = makeBuilder().build(context: ctx)
        #expect(!prompt.contains("## Project Settings"))
        #expect(!prompt.contains("## Project Memory"))
    }

    @Test("Project with empty memory → no project memory block")
    func projectWithEmptyMemoryHasNoMemoryBlock() {
        let projectCtx = PromptContext.ProjectContext(
            name: "EmptyProject",
            settings: ProjectSettings(agentRole: .advisor),
            memory: []
        )
        let prompt = makeBuilder().build(context: PromptContext(projects: [projectCtx]))
        #expect(prompt.contains("Project Settings: EmptyProject"))
        #expect(!prompt.contains("## Project Memory: EmptyProject"))
    }

    // MARK: - Two independent contexts share no state (zero leakage)

    @Test("Two independent PromptContexts produce independent prompts")
    func twoContextsAreCompletelyIndependent() {
        let builder = makeBuilder()

        let ctx1 = PromptContext(
            userName: "Alice",
            threadMemory: [makeEntry(key: "thread1_key", value: "thread 1 data")]
        )
        let ctx2 = PromptContext(
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

    // MARK: - Thread terminal access

    @Test("Thread terminal access is never injected into the prompt (the tool status carries it)",
          arguments: [TerminalAccessLevel.none, .confirm, .auto])
    func threadTerminalNotInjected(access: TerminalAccessLevel) {
        let ctx = PromptContext(threadTerminalAccess: access)
        let prompt = makeBuilder().build(context: ctx)
        #expect(!prompt.contains("Thread Settings"))
        #expect(!prompt.contains("Terminal:"))
    }

    // MARK: - Project settings block (facts only; tool statuses carry access state)

    @Test("Project terminal setting never reaches the prompt",
          arguments: [TerminalAccessLevel.none, .confirm, .auto])
    func projectTerminalNotInjected(access: TerminalAccessLevel) {
        var settings = ProjectSettings()
        settings.terminalAccess = access
        let project = makeProject(settings: settings)
        let prompt = makeBuilder().build(context: PromptContext(projects: [project]))
        let section = extractProjectSection(from: prompt, projectName: project.name)
        #expect(!section.contains("Terminal"))
    }

    @Test("Advisor project block is the header and the path only")
    func advisorBlockIsPathOnly() {
        let block = ProjectSettings(agentRole: .advisor, isProgrammingProject: true)
            .formatForSystemPrompt(projectName: "Docs", absolutePath: "/tmp/docs")
        #expect(block == "## Project Settings: Docs\n- Absolute path: /tmp/docs")
    }

    @Test("Executor without programming flag is the header and the path only")
    func nonProgrammingExecutorBlockIsPathOnly() {
        let block = ProjectSettings(agentRole: .executor, isProgrammingProject: false)
            .formatForSystemPrompt(projectName: "Notes", absolutePath: "/tmp/notes")
        #expect(block == "## Project Settings: Notes\n- Absolute path: /tmp/notes")
    }

    @Test("Programming executor block holds only facts, no role, git, compilation or rule text")
    func programmingExecutorBlockIsCompact() {
        var settings = ProjectSettings(agentRole: .executor, isProgrammingProject: true)
        settings.devEnvironment = .xcode
        settings.testsAccess = .write
        settings.architectureEnabled = true
        settings.commentsEnabled = true
        let block = settings.formatForSystemPrompt(projectName: "App", absolutePath: "/tmp/app")
        #expect(block.contains("- Absolute path: /tmp/app"))
        #expect(block.contains("- Dev environment:"))
        #expect(block.contains("- Tests: creating tests allowed"))
        #expect(block.contains("- Architecture files: enabled ("))
        #expect(block.contains("- Code comments: enabled ("))
        for gone in ["Role:", "Programming project:", "Git:", "Compilation:", "Access:", "Discuss file paths", "Be concise"] {
            #expect(!block.contains(gone), "\(gone) must not be in the block")
        }
    }

    @Test("Disabled switches say how to enable them")
    func disabledSwitchesHintAtSettings() {
        var settings = ProjectSettings(agentRole: .executor, isProgrammingProject: true)
        settings.testsAccess = .run
        settings.architectureEnabled = false
        settings.commentsEnabled = false
        let block = settings.formatForSystemPrompt(projectName: "App")
        #expect(block.contains("- Tests: creating new tests not allowed"))
        #expect(block.contains("- Architecture files: read-only (enable write in project settings)"))
        #expect(block.contains("- Code comments: disabled (enable in project settings)"))
    }
}
