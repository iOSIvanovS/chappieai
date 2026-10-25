// OutputGuardTests.swift
// ChappieCoreTests
//
// The single size gate for tool results: thresholds on PREPARED text (UTF-8 bytes), the notice
// instead of a cut piece, memory-safe collection of command output, and the gate being wired
// into the one execution entry point.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Thresholds

@Suite("OutputGuard — thresholds")
struct OutputGuardThresholdTests {

    @Test("Read results: exactly the limit passes, one byte more is refused")
    func readBoundary() {
        let atLimit = String(repeating: "a", count: OutputGuard.readLimit)
        #expect(OutputGuard.apply(toolName: "read_file", output: atLimit) == atLimit)

        let over = atLimit + "a"
        let result = OutputGuard.apply(toolName: "read_file", output: over)
        #expect(result != over)
        #expect(result.contains("DATA NOT PASSED"))
        #expect(result.contains("200.0 KB"))
    }

    @Test("Command output: the stricter 100 KB limit applies")
    func commandBoundary() {
        let atLimit = String(repeating: "a", count: OutputGuard.commandLimit)
        #expect(OutputGuard.apply(toolName: "run_terminal", output: atLimit) == atLimit)

        let result = OutputGuard.apply(toolName: "run_terminal", output: atLimit + "a")
        #expect(result.contains("OUTPUT NOT PASSED"))
        // The same size is fine for a read tool (100 KB < 200 KB).
        let sameForRead = String(repeating: "a", count: OutputGuard.commandLimit + 1)
        #expect(OutputGuard.apply(toolName: "search_in_project", output: sameForRead) == sameForRead)
    }

    @Test("Size is counted in UTF-8 bytes, not characters")
    func utf8Bytes() {
        // Cyrillic letters take 2 bytes: 110 000 characters = 220 000 bytes, over the 200 KB limit.
        let text = String(repeating: "я", count: 110_000)
        #expect(text.count < OutputGuard.readLimit)
        #expect(OutputGuard.apply(toolName: "read_document", output: text).contains("DATA NOT PASSED"))
    }

    @Test("Notices name the real size and tell the model to ask the user for less data")
    func noticeText() {
        let read = OutputGuard.oversizeNotice(toolName: "read_file", bytes: 4_400_000)
        #expect(read.contains("4.2 MB"))
        #expect(read.contains("ask them to give you less data"))
        #expect(read.contains("Do not pretend"))

        let command = OutputGuard.oversizeNotice(toolName: "run_tests", bytes: 2_500_000)
        #expect(command.contains("has finished"))
        #expect(command.contains("do not re-run it blindly"))
    }

    @Test("An image data URI is not judged by the text limit")
    func viewImageExempt() {
        let big = ToolExecutionService.viewImageMarker + String(repeating: "A", count: 3_000_000)
        #expect(OutputGuard.apply(toolName: "view_image", output: big) == big)
    }

    @Test("Every command tool is a classified tool, so the strict limit cannot silently miss one")
    func commandToolsAreClassified() {
        #expect(OutputGuard.commandTools.isSubset(of: ToolPolicy.knownTools))
        #expect(OutputGuard.kind(of: "run_terminal") == .command)
        #expect(OutputGuard.kind(of: "git_push") == .command)
        #expect(OutputGuard.kind(of: "read_build_log") == .read)
        #expect(OutputGuard.kind(of: "a_future_tool") == .read)
    }
}

// MARK: - Capture

@Suite("OutputCapture — memory-safe collection")
struct OutputCaptureTests {

    @Test("Small output is stored whole and carries no marker")
    func smallOutput() {
        let capture = OutputCapture(headLimit: 100, tailWindow: 16)
        capture.append(Data("hello ".utf8))
        capture.append(Data("world".utf8))
        #expect(capture.text() == "hello world")
        #expect(!capture.isTruncated)
        #expect(capture.totalBytes == 11)
    }

    @Test("Past the cap nothing more is stored, but every byte is counted")
    func capStopsStoring() {
        let capture = OutputCapture(headLimit: 100, tailWindow: 16)
        for _ in 0..<50 { capture.append(Data(String(repeating: "x", count: 100).utf8)) }
        #expect(capture.isTruncated)
        #expect(capture.totalBytes == 5000)
        #expect(capture.headText.utf8.count == 100)
        #expect(capture.tailText.utf8.count <= 16)
        #expect(capture.text().hasSuffix(OutputGuard.truncationMarker(totalBytes: 5000)))
    }

    @Test("The tail window still shows the end of a huge stream")
    func tailWindowSeesTheEnd() {
        let capture = OutputCapture(headLimit: 10, tailWindow: 32)
        capture.append(Data(String(repeating: "z", count: 10_000).utf8))
        capture.append(Data("EXIT_CODE:3\nDONE".utf8))
        #expect(capture.tailText.contains("EXIT_CODE:3"))
        #expect(capture.tailText.hasSuffix("DONE"))
    }

    @Test("A truncated result is judged by its real size, not by what was stored")
    func gateUsesRealSize() {
        let capture = OutputCapture(headLimit: 1000, tailWindow: 16)
        capture.append(Data(String(repeating: "x", count: 5_000_000).utf8))
        let stored = capture.text()
        #expect(stored.utf8.count < OutputGuard.commandLimit)
        let verdict = OutputGuard.apply(toolName: "run_terminal", output: stored)
        #expect(verdict.contains("OUTPUT NOT PASSED"))
        #expect(verdict.contains("4.8 MB"))
    }

    @Test("Markers of stdout and stderr add up")
    func markersAddUp() {
        let joined = "out\n" + OutputGuard.truncationMarker(totalBytes: 150_000)
            + "\nstderr: err\n" + OutputGuard.truncationMarker(totalBytes: 90_000)
        #expect(OutputGuard.truncatedTotal(in: joined) == 240_000)
        #expect(OutputGuard.truncatedTotal(in: "no marker here") == nil)
    }

    @Test("A cut inside a multi-byte character does not lose the text")
    func cutInsideCharacter() {
        let capture = OutputCapture(headLimit: 5, tailWindow: 8)
        capture.append(Data("ааааа".utf8))        // 10 bytes, cap 5 falls in the middle of a letter
        #expect(!capture.headText.isEmpty)
        #expect(capture.isTruncated)
    }
}

// MARK: - Shell integration

@Suite("OutputGuard — shell sessions")
struct OutputGuardShellTests {

    @Test("A runaway command is capped in memory and the real size reaches the notice")
    func runawayCommand() async {
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory())
        // 1 MB of output, far above the capture cap.
        let result = await shell.run("/usr/bin/head -c 1000000 /dev/zero | /usr/bin/tr '\\0' 'a'", timeout: 60)
        #expect(result.output.utf8.count < OutputGuard.captureCap + 200, "memory must not follow the output size")
        #expect(result.exitCode == 0, "the exit code comes from the tail window")

        let verdict = OutputGuard.apply(toolName: "run_terminal", output: result.formatted)
        #expect(verdict.contains("OUTPUT NOT PASSED"))
        #expect(verdict.contains("MB") || verdict.contains("KB"))
    }

    @Test("Output between the command limit and the capture cap is refused with its exact size")
    func middleSizedOutput() async {
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory())
        let result = await shell.run("/usr/bin/head -c 150000 /dev/zero | /usr/bin/tr '\\0' 'a'", timeout: 60)
        #expect(result.exitCode == 0)
        #expect(OutputGuard.apply(toolName: "run_terminal", output: result.formatted).contains("OUTPUT NOT PASSED"))
    }

    @Test("Normal commands are untouched, exit code included")
    func normalCommand() async {
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory())
        let ok = await shell.run("echo hello", timeout: 10)
        #expect(OutputGuard.apply(toolName: "run_terminal", output: ok.formatted) == ok.formatted)
        let bad = await shell.run("echo oops; false", timeout: 10)
        #expect(bad.exitCode == 1)
        #expect(bad.output == "oops")
    }
}

// MARK: - The one entry point

@Suite("OutputGuard — wired into ToolExecutionService.execute")
struct OutputGuardWiringTests {

    private func makeService(root: URL) async -> ToolExecutionService {
        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaces: [(name: "P", url: root)]),
            memoryManager: MemoryManager(workspaceURL: root),
            socketPath: "/tmp/chappie-outputguard-tests-nonexistent.sock"
        )
        let info = ActiveMemoryContext.ProjectInfo(id: UUID(), name: "P")
        let settings = ProjectSettings(agentRole: .executor, isProgrammingProject: true, devEnvironment: .xcode)
        await service.setMemoryContextAndSettings(
            context: ActiveMemoryContext(threadId: UUID(), projects: [info], threadTerminalAccess: .none),
            settings: [info.id: settings]
        )
        return service
    }

    private func call(_ tool: String, _ json: String) -> AIToolCall {
        AIToolCall(id: "t1", type: "function", function: AIToolCallFunction(name: tool, arguments: json))
    }

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("og-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("read_file refuses a file over the limit before loading it, and passes one at the limit")
    func readFileBoundary() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try String(repeating: "a", count: OutputGuard.readLimit + 1).write(
            to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "a", count: OutputGuard.readLimit).write(
            to: root.appendingPathComponent("edge.txt"), atomically: true, encoding: .utf8)
        let service = await makeService(root: root)

        let big = await service.execute(call: call("read_file", #"{"path":"big.txt","project":"P"}"#))
        #expect(big.contains("DATA NOT PASSED"))
        #expect(big.utf8.count < 2000)

        let edge = await service.execute(call: call("read_file", #"{"path":"edge.txt","project":"P"}"#))
        #expect(edge.utf8.count == OutputGuard.readLimit)
    }

    @Test("A text file of a normal size is returned as it is")
    func smallFileUntouched() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let service = await makeService(root: root)
        let result = await service.execute(call: call("read_file", #"{"path":"a.txt","project":"P"}"#))
        #expect(result == "hello")
    }

    @Test("A search that matches everything is caught by the same gate, with no per-tool code")
    func searchResultIsGuarded() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 300 files, each a matching line: the prepared search text is far above 200 KB.
        for index in 0..<300 {
            let line = String(repeating: "needle ", count: 150) + "\n"
            try String(repeating: line, count: 3).write(
                to: root.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8)
        }
        let service = await makeService(root: root)
        let result = await service.execute(call: call("search_in_project", #"{"query":"needle","project":"P"}"#))
        #expect(result.contains("DATA NOT PASSED"))
    }
}
