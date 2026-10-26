// ToolWatchdogTests.swift
// ChappieCoreTests
//
// The deadline table and the watchdog that enforces it. Real clocks, but with sub-second deadlines.

import Testing
import Foundation
@testable import ChappieCore

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("ToolDeadlines — one table of allowed run times")
struct ToolDeadlinesTests {

    @Test("classes get the agreed deadlines")
    func classes() {
        #expect(ToolDeadlines.seconds(tool: "read_file", arguments: "{}") == 120)
        #expect(ToolDeadlines.seconds(tool: "web_fetch", arguments: "{}") == 120)
        #expect(ToolDeadlines.seconds(tool: "git_status", arguments: "{}") == 180)
        #expect(ToolDeadlines.seconds(tool: "git_commit", arguments: "{}") == 720)
        #expect(ToolDeadlines.seconds(tool: "git_push", arguments: "{}") == 720)
        #expect(ToolDeadlines.seconds(tool: "build_project", arguments: "{}") == 1200)
        #expect(ToolDeadlines.seconds(tool: "run_tests", arguments: "{}") == 1200)
        #expect(ToolDeadlines.seconds(tool: "run_terminal", arguments: "{}") == 300)
    }

    @Test("every classified tool has a positive deadline")
    func everyToolCovered() {
        for tool in ToolPolicy.knownTools {
            #expect(ToolDeadlines.seconds(tool: tool, arguments: "{}") > 0)
        }
    }

    @Test("a terminal call asking for a longer timeout gets it, plus grace, up to the ceiling")
    func terminalLongerTimeout() {
        #expect(ToolDeadlines.seconds(tool: "run_terminal", arguments: #"{"timeout":"600"}"#) == 630)
        #expect(ToolDeadlines.seconds(tool: "run_terminal", arguments: #"{"timeout":900}"#) == 930)
        #expect(ToolDeadlines.seconds(tool: "run_terminal", arguments: #"{"timeout":"99999"}"#) == 1800)
        // A shorter request never lowers the base: the watchdog is the backstop, not the shell timeout.
        #expect(ToolDeadlines.seconds(tool: "run_terminal", arguments: #"{"timeout":"10"}"#) == 300)
        #expect(ToolDeadlines.seconds(tool: "run_ssh", arguments: #"{"timeout":"nonsense"}"#) == 300)
    }

    @Test("mutating tools are told the outcome is unknown, readers are told nothing changed")
    func messages() {
        #expect(ToolDeadlines.isMutating("write_file"))
        #expect(ToolDeadlines.isMutating("git_push"))
        #expect(ToolDeadlines.isMutating("run_terminal"))
        #expect(ToolDeadlines.isMutating("loc_delete"))
        #expect(!ToolDeadlines.isMutating("read_file"))
        #expect(!ToolDeadlines.isMutating("git_status"))
        #expect(!ToolDeadlines.isMutating("build_project"))

        let unknown = ToolDeadlines.timeoutMessage(tool: "git_push", seconds: 720)
        #expect(unknown.contains("RESULT IS UNKNOWN"))
        #expect(unknown.contains("12 minutes"))
        #expect(unknown.contains("do not repeat"))

        let readOnly = ToolDeadlines.timeoutMessage(tool: "read_file", seconds: 120)
        #expect(readOnly.contains("Nothing was changed"))
        #expect(!readOnly.contains("UNKNOWN"))
    }

    @Test("durations are described in words")
    func describe() {
        #expect(ToolDeadlines.describe(1) == "1 second")
        #expect(ToolDeadlines.describe(45) == "45 seconds")
        #expect(ToolDeadlines.describe(60) == "1 minute")
        #expect(ToolDeadlines.describe(1200) == "20 minutes")
    }
}

@Suite("ToolWatchdog — a tool that never answers cannot hold the chain")
struct ToolWatchdogTests {

    @Test("a fast tool returns its own result untouched")
    func fastTool() async {
        let result = await ToolWatchdog.run(toolName: "read_file", seconds: 5) { "done" }
        #expect(result == "done")
    }

    @Test("a hung tool is cancelled and the model gets the watchdog message")
    func hungTool() async {
        let cancelled = Flag()
        let started = Date()
        let result = await ToolWatchdog.run(toolName: "read_file", seconds: 0.3) {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled.set() }
            return "never"
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.contains("did not answer"))
        #expect(result.contains("`read_file`"))
        // The operation was told to stop (that is what kills the helper's processes in the real app).
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(cancelled.isSet)
    }

    @Test("a tool that ignores cancellation still cannot hold the caller; its late result is dropped")
    func uncancellableTool() async {
        let started = Date()
        let result = await ToolWatchdog.run(toolName: "git_push", seconds: 0.3) {
            // A blocking call nothing can interrupt (think: a dead network volume).
            usleep(1_500_000)
            return "late result"
        }
        let waited = Date().timeIntervalSince(started)
        #expect(waited < 1.2)
        #expect(result.contains("RESULT IS UNKNOWN"))
        #expect(!result.contains("late result"))
    }

    @Test("Stop on the caller reaches the tool and the call returns")
    func callerCancellation() async {
        let cancelled = Flag()
        let task = Task {
            await ToolWatchdog.run(toolName: "run_terminal", seconds: 60) {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled.set() }
                return "cancelled-result"
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.value
        #expect(cancelled.isSet)
        #expect(result == "cancelled-result")   // the tool's own cancel message is what comes back
    }

    @Test("the wired entry point applies the watchdog: an answering tool is unchanged")
    func wiredFastPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaces: [(name: "P", url: root)]),
            memoryManager: MemoryManager(workspaceURL: root),
            socketPath: "/tmp/chappie-watchdog-tests-nonexistent.sock"
        )
        let info = ActiveMemoryContext.ProjectInfo(id: UUID(), name: "P")
        let settings = ProjectSettings(agentRole: .executor, isProgrammingProject: true, devEnvironment: .xcode)
        await service.setMemoryContextAndSettings(
            context: ActiveMemoryContext(threadId: UUID(), projects: [info], threadTerminalAccess: .none),
            settings: [info.id: settings]
        )
        let call = AIToolCall(
            id: "t1", type: "function",
            function: AIToolCallFunction(name: "read_file", arguments: #"{"path":"P/a.txt","project":"P"}"#)
        )
        let result = await service.execute(call: call)
        #expect(result.contains("hello"))
    }
}
