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

    @Test("Empty context contains persona block and terminal section")
    func emptyContextContainsPersonaAndTerminal() {
        let prompt = makeBuilder().build(context: .empty)
        // Terminal block is always injected (even for .none) — persona must be first
        #expect(prompt.hasPrefix(persona))
        #expect(prompt.contains("Terminal:"))
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
        #expect(prompt.contains("## Thread Context"))
        #expect(prompt.contains("task_context"))
    }

    @Test("Thread memory section is OMITTED when empty")
    func threadMemorySectionOmittedWhenEmpty() {
        let prompt = makeBuilder().build(context: PromptContext(threadMemory: []))
        #expect(!prompt.contains("## Thread Context"))
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

    @Test("Terminal BLOCKED → prompt contains BLOCKED message")
    func terminalBlockedIsInjected() {
        let ctx = PromptContext(threadTerminalAccess: .none)
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("Terminal: BLOCKED"))
    }

    @Test("Terminal confirm → prompt contains confirmation requirement")
    func terminalConfirmIsInjected() {
        let ctx = PromptContext(threadTerminalAccess: .confirm)
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("enabled with confirmation"))
        #expect(prompt.contains("ask the user for explicit approval"))
    }

    @Test("Terminal auto → prompt contains auto-execute message")
    func terminalAutoIsInjected() {
        let ctx = PromptContext(threadTerminalAccess: .auto)
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("auto-execute"))
    }

    @Test("Terminal section always present — even for empty context")
    func terminalSectionAlwaysPresent() {
        let prompt = makeBuilder().build(context: .empty)
        #expect(prompt.contains("## Thread Settings: Terminal"))
    }

    // MARK: - Project-level terminal access

    @Test("Project terminal .none → BLOCKED not injected into project settings")
    func projectTerminalNoneNotInjected() {
        // WHY: thread-level terminal takes precedence; project should stay silent when blocked
        var settings = ProjectSettings()
        settings.terminalAccess = .none
        let project = makeProject(settings: settings)
        let ctx = PromptContext(projects: [project])
        let prompt = makeBuilder().build(context: ctx)
        // thread section may say BLOCKED, but project section must not repeat it
        let projectSection = extractProjectSection(from: prompt, projectName: project.name)
        #expect(!projectSection.contains("Terminal: BLOCKED"))
    }

    @Test("Project terminal .confirm → confirmation message in project settings")
    func projectTerminalConfirmIsInjected() {
        var settings = ProjectSettings()
        settings.terminalAccess = .confirm
        let project = makeProject(settings: settings)
        let ctx = PromptContext(projects: [project])
        let prompt = makeBuilder().build(context: ctx)
        #expect(prompt.contains("enabled with confirmation"))
    }

    @Test("Project terminal .auto → auto-execute message in project settings")
    func projectTerminalAutoIsInjected() {
        var settings = ProjectSettings()
        settings.terminalAccess = .auto
        let project = makeProject(settings: settings)
        let ctx = PromptContext(projects: [project])
        let prompt = makeBuilder().build(context: ctx)
        let projectSection = extractProjectSection(from: prompt, projectName: project.name)
        #expect(projectSection.contains("auto-execute"))
    }
}
