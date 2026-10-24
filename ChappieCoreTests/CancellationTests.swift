// CancellationTests.swift
// ChappieCoreTests
//
// Stop must reach running tools: the shell session, the helper socket call and the process tree.
// The helper side (ProcessRunner, ClientWatcher) lives in ChappieMCP, which has no test target;
// it is verified live against a real helper, see the backlog notes.

import Testing
import Foundation
@testable import ChappieCore

/// Counts live processes whose command line contains `marker` (pgrep -f).
private func processCount(matching marker: String) -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", marker]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").filter { !$0.isEmpty }.count
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

/// Waits until `root` has `count` descendants and returns them (empty if that never happens).
/// Tracks real pids on purpose: `pgrep -f` also matches the `bash -c` line that carries the marker.
private func awaitDescendants(of root: pid_t, count: Int, timeout: TimeInterval = 5) async -> [pid_t] {
    var found: [pid_t] = []
    _ = await waitUntil(timeout: timeout) {
        found = ProcessTree.descendants(of: root)
        return found.count >= count
    }
    return found
}

private func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

@Suite("ProcessTree")
struct ProcessTreeTests {

    @Test("terminate() stops the root and its descendants")
    func killsWholeTree() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // bash -> sleep (background) and bash -> sleep (foreground). Absolute paths: under the helper the
        // test run has no /bin in PATH.
        p.arguments = ["-c", "/bin/sleep 60 & /bin/sleep 61; wait"]
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let kids = await awaitDescendants(of: p.processIdentifier, count: 2)
        try #require(kids.count >= 2)

        ProcessTree.terminate(rootPid: p.processIdentifier, grace: 1)

        #expect(await waitUntil(timeout: 5) { !p.isRunning })
        for pid in kids { #expect(await waitUntil(timeout: 5) { isGone(pid) }, "child \(pid) survived") }
    }

    @Test("A child that ignores SIGTERM is killed after the grace period")
    func sigkillAfterGrace() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "trap '' TERM; /bin/sleep 60 & wait"]
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let kids = await awaitDescendants(of: p.processIdentifier, count: 1)
        try #require(!kids.isEmpty)
        // Give bash time to install the trap before we signal it.
        try await Task.sleep(nanoseconds: 300_000_000)

        ProcessTree.terminate(rootPid: p.processIdentifier, grace: 1)

        // The shell shrugs off SIGTERM, so it is still there right after the signal...
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(p.isRunning)
        // ...and gone once the grace period has passed.
        #expect(await waitUntil(timeout: 6) { !p.isRunning })
        for pid in kids { #expect(await waitUntil(timeout: 5) { isGone(pid) }, "child \(pid) survived") }
    }

    @Test("A recycled pid is not killed: identity compares the start time")
    func identityDiffersAcrossProcesses() throws {
        let a = Process(); a.executableURL = URL(fileURLWithPath: "/bin/sleep"); a.arguments = ["30"]
        try a.run()
        defer { kill(a.processIdentifier, SIGKILL) }
        let first = ProcessTree.identity(of: a.processIdentifier)
        #expect(first != nil)
        #expect(first == ProcessTree.identity(of: a.processIdentifier))
        #expect(ProcessTree.identity(of: 0x7FFF_FFF0) == nil)
    }

    @Test("terminate() ignores pid 0 and 1")
    func refusesSystemPids() {
        ProcessTree.terminate(rootPid: 0)
        ProcessTree.terminate(rootPid: 1)
        #expect(ProcessTree.exists(1))
    }

    @Test("ProcessCanceller applies a Stop that arrives before the pid is known")
    func cancelBeforeAttach() async throws {
        let marker = "pcan-\(UUID().uuidString.prefix(8))"
        let canceller = ProcessCanceller()
        canceller.stop(.cancelled)                       // Stop first...
        #expect(canceller.stopReason == .cancelled)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "exec -a \(marker) /bin/sleep 60"]
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        canceller.attach(pid: p.processIdentifier)       // ...then the process appears

        #expect(await waitUntil(timeout: 5) { !p.isRunning })
    }

    @Test("The first stop reason wins")
    func firstReasonWins() {
        let canceller = ProcessCanceller()
        canceller.stop(.timedOut)
        canceller.stop(.cancelled)
        #expect(canceller.stopReason == .timedOut)
    }

    @Test("Core and MCP copies of ProcessTree.swift are identical")
    func copiesAreIdentical() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let core = repo.appendingPathComponent("ChappieCore/Sources/ChappieCore/Services/ProcessControl/ProcessTree.swift")
        let mcp = repo.appendingPathComponent("ChappieMCP/Sources/ChappieMCP/Tools/ProcessTree.swift")
        let coreText = try String(contentsOf: core, encoding: .utf8)
        let mcpText = try String(contentsOf: mcp, encoding: .utf8)
        #expect(coreText == mcpText, "ProcessTree.swift copies drifted apart — copy the Core file over the MCP one")
    }
}

@Suite("ShellSession cancellation")
struct ShellSessionCancellationTests {

    @Test("Cancelling a running command returns quickly and stops the command")
    func cancelStopsCommand() async throws {
        let marker = "shcan-\(UUID().uuidString.prefix(8))"
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory())

        let started = Date()
        let task = Task { await shell.run("exec -a \(marker) /bin/sleep 60", timeout: 120) }
        #expect(await waitUntil(timeout: 5) { processCount(matching: marker) == 1 })

        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.output.contains("cancelled"))
        #expect(elapsed < 5, "Stop must not wait for the 60s command")
        #expect(await waitUntil(timeout: 6) { processCount(matching: marker) == 0 })
    }

    @Test("The session is usable again after a cancel")
    func sessionRecovers() async throws {
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory())
        let task = Task { await shell.run("/bin/sleep 60", timeout: 120) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        _ = await task.value

        let next = await shell.run("echo alive", timeout: 10)
        #expect(next.isSuccess)
        #expect(next.output.contains("alive"))
    }

    @Test("A command that finishes normally is not affected by the cancel plumbing")
    func normalCommandUnaffected() async {
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory())
        let result = await shell.run("echo hello", timeout: 10)
        #expect(result.isSuccess)
        #expect(result.output == "hello")
    }
}

@Suite("MCPToolBridge cancellation")
struct MCPToolBridgeCancellationTests {

    /// A "helper" that accepts the request and then never answers.
    private final class SilentServer: @unchecked Sendable {
        private(set) var listener: Int32 = -1
        private let lock = NSLock()
        private var clientClosed = false
        var sawHangUp: Bool { lock.withLock { clientClosed } }

        func start(at path: String) throws {
            listener = try MCPSocketTests.listen(on: path)
            let fd = listener
            DispatchQueue.global().async { [self] in
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var header = [UInt8](repeating: 0, count: 4)
                _ = recv(client, &header, 4, MSG_WAITALL)
                let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                var body = [UInt8](repeating: 0, count: length)
                _ = recv(client, &body, length, MSG_WAITALL)
                // Wait for the client to hang up, like the real helper's watcher does.
                var byte: UInt8 = 0
                _ = recv(client, &byte, 1, 0)
                lock.withLock { clientClosed = true }
            }
        }

        func stop(_ path: String) {
            if listener >= 0 { close(listener) }
            unlink(path)
        }
    }

    @Test("Cancelling returns at once and hangs up on the helper")
    func cancelReturnsPromptly() async throws {
        let path = "/tmp/mcpc-\(getpid())-\(Int.random(in: 1000...9999)).sock"
        let server = SilentServer()
        try server.start(at: path)
        defer { server.stop(path) }
        let bridge = MCPToolBridge(socketPath: path, timeoutSeconds: 120)

        let started = Date()
        let task = Task { await bridge.execute(tool: "build_project") }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let result = await task.value

        #expect(Date().timeIntervalSince(started) < 5, "Stop must not wait for the helper")
        #expect(result.contains("cancelled"))
        #expect(await waitUntil(timeout: 3) { server.sawHangUp }, "the helper must see the hang-up to kill the tool")
    }

    @Test("A task that is already cancelled does not recover and retry")
    func cancelledTaskDoesNotRecover() async {
        let bridge = MCPToolBridge(socketPath: "/tmp/definitely-missing-\(UUID().uuidString).sock")
        let calls = RecoveryCounter()
        await bridge.setRecoveryHandler { await calls.bump() }

        let task = Task { () -> String in
            try? await Task.sleep(nanoseconds: 100_000_000)   // let the cancel land first
            return await bridge.execute(tool: "git_status")
        }
        task.cancel()
        _ = await task.value

        #expect(await calls.value() == 0)
    }

    private actor RecoveryCounter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
}
