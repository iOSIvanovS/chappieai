// ProcessRunnerTests.swift
//
// ProcessRunner is the one place that runs build, git and converter processes. Every bug it
// fixed (pipe deadlock, hanging command, "Stop" that did not stop) gets a test here.

import Testing
import Foundation
@testable import ChappieMCPCore

struct ProcessRunnerTests {

    private let env = ["PATH": ProcessRunner.toolSearchPath]

    private func shell(_ script: String, timeout: TimeInterval? = 20, cancellable: Bool = true) async -> ProcessRun {
        await ProcessRunner.run(
            executable: "/bin/sh", args: ["-c", script], environment: env,
            timeout: timeout, cancellable: cancellable
        )
    }

    /// Polls until `condition` holds or `seconds` pass.
    private func eventually(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test func capturesStdoutStderrAndExitCode() async {
        let run = await shell("echo out; echo err 1>&2; exit 3")
        #expect(run.stdoutText == "out\n")
        #expect(run.stderrText == "err\n")
        #expect(run.exitCode == 3)
        #expect(run.stopReason == nil)
        #expect(run.launchError == nil)
    }

    @Test func largeStderrDoesNotDeadlock() async {
        // 250 KB of stderr: far past the ~64 KB pipe buffer. The old loop read stderr only after
        // the process exited, so the child blocked on write and never exited.
        let run = await shell("head -c 250000 /dev/zero | tr '\\0' x 1>&2; echo done")
        #expect(run.stopReason == nil)
        #expect(run.stderr.count == 250_000)
        #expect(run.stdoutText == "done\n")
    }

    @Test func largeStdoutAndStderrTogether() async {
        let run = await shell("head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero | tr '\\0' b 1>&2")
        #expect(run.stdout.count == 300_000)
        #expect(run.stderr.count == 300_000)
    }

    @Test func pathContainsBinSoHooksFindBasicTools() async {
        // A PATH without /bin made "sleep" and "cat" fail with "command not found" inside hooks.
        let run = await shell("command -v sleep && command -v cat && command -v rm")
        #expect(run.exitCode == 0)
    }

    @Test func missingExecutableReportsLaunchError() async {
        let run = await ProcessRunner.run(executable: "/nonexistent/tool", args: [], environment: env)
        #expect(run.launchError != nil)
        #expect(run.exitCode == -1)
    }

    @Test func timeoutStopsTheProcess() async {
        let started = Date()
        let run = await shell("sleep 30", timeout: 0.5)
        #expect(run.stopReason == .timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cancellationStopsTheWholeTree() async throws {
        let pidFile = NSTemporaryDirectory() + "mcp-runner-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        // The shell starts a grandchild (sleep) and waits for it, like xcodebuild and its compilers.
        let task = Task { await shell("sleep 60 & echo $! > \(pidFile); wait", timeout: nil) }

        #expect(await eventually(5) { FileManager.default.fileExists(atPath: pidFile) })
        let pid = try #require(Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(ProcessTree.exists(pid))

        let started = Date()
        task.cancel()
        let run = await task.value

        #expect(run.stopReason == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10)
        // The grandchild must be gone too, not orphaned.
        #expect(await eventually(6) { !ProcessTree.exists(pid) || isZombie(pid) })
    }

    @Test func nonCancellableCommandFinishesDespiteCancel() async {
        // Mutating git commands must not be killed halfway: cancellable: false ignores "Stop".
        let task = Task { await shell("sleep 1; echo finished", timeout: 20, cancellable: false) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let run = await task.value
        #expect(run.stopReason == nil)
        #expect(run.stdoutText == "finished\n")
    }

    @Test func firstStopReasonWins() {
        let canceller = ProcessCanceller()
        canceller.stop(.timedOut)
        canceller.stop(.cancelled)
        #expect(canceller.stopReason == .timedOut)
    }

    /// A killed child that nobody reaped yet still answers kill(pid, 0); treat it as gone.
    private func isZombie(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
        return info.pbi_status == UInt32(SZOMB)
    }
}
