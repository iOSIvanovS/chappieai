// SSHResultTests.swift
// ChappieCoreTests
//
// What the model reads after a run_ssh call. Covered through the output collectors instead of a
// real ssh host: no host is available in tests, and the interesting part is the shaping of the text,
// not the connection.
//
// The spool cases are the reason this file exists: without a spool directory a runaway remote
// command loses everything past the capture cap, and OutputGuard then refuses the whole result.

import Testing
import Foundation
@testable import ChappieCore

private func dir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ssh-result-\(UUID().uuidString)", isDirectory: true)
}

@Suite("SSHResult — shaping the output")
struct SSHResultTests {

    @Test("A successful command prefixes the output with a check mark")
    func success() {
        let out = OutputCapture(headLimit: 1000, tailWindow: 64)
        out.append(Data("hello\nworld\n".utf8))
        let text = SSHResult.finished(exitCode: 0, stdout: out, stderr: OutputCapture())
        #expect(text == "✅\nhello\nworld")
    }

    @Test("Silence is reported as such, not as an empty result")
    func emptySuccess() {
        let text = SSHResult.finished(exitCode: 0, stdout: OutputCapture(), stderr: OutputCapture())
        #expect(text == "✅ Command completed successfully (no output).")
    }

    @Test("A failure carries the code, both streams and the stderr label")
    func failure() {
        let out = OutputCapture(headLimit: 1000, tailWindow: 64)
        out.append(Data("partial\n".utf8))
        let err = OutputCapture(headLimit: 1000, tailWindow: 64)
        err.append(Data("permission denied\n".utf8))
        let text = SSHResult.finished(exitCode: 2, stdout: out, stderr: err)
        #expect(text == "❌ (exit code 2)\npartial\nstderr: permission denied")
    }

    @Test("A failure with no output still names the code")
    func failureSilent() {
        let text = SSHResult.finished(exitCode: 255, stdout: OutputCapture(), stderr: OutputCapture())
        #expect(text == "❌ (exit code 255)")
    }

    @Test("With a spool a huge stream becomes a notice, and the file holds every byte")
    func hugeStreamSpools() throws {
        let folder = dir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = OutputCapture(headLimit: 400, tailWindow: 64, spoolDirectory: folder, spoolThreshold: 100)
        // Deliberately over OutputGuard.commandLimit: below it the collector hands the whole text back
        // (and drops the file), which is the behaviour of `borderlineInline` on the shell side.
        var expected = ""
        for index in 0..<9000 {
            let line = "remote line \(index)\n"
            expected += line
            out.append(Data(line.utf8))
        }
        #expect(expected.utf8.count > OutputGuard.commandLimit, "the fixture must outgrow the limit")
        let text = SSHResult.finished(exitCode: 0, stdout: out, stderr: OutputCapture())

        #expect(text.contains("OUTPUT TOO LONG TO SHOW"))
        #expect(text.contains("remote line 0"), "the beginning is shown")
        #expect(text.contains("remote line 8999"), "the end is shown")
        #expect(text.utf8.count < 40_000, "the model gets a short piece, not the stream")

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let name = try #require(files.first, "the spool file must exist")
        let saved = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        #expect(saved == expected)
        #expect(text.contains(folder.path), "the notice names the file")

        #expect(OutputGuard.apply(toolName: "run_ssh", output: text) == text,
                "the gate lets the notice through")
    }

    @Test("Without a spool the same stream is refused outright by the gate")
    func hugeStreamWithoutSpool() {
        let out = OutputCapture(headLimit: 100, tailWindow: 64)
        out.append(Data(String(repeating: "x", count: 300_000).utf8))
        let text = SSHResult.finished(exitCode: 0, stdout: out, stderr: OutputCapture())
        let verdict = OutputGuard.apply(toolName: "run_ssh", output: text)
        #expect(verdict.contains("OUTPUT NOT PASSED"))
        #expect(!verdict.contains("xxx"), "the model is left blind — this is why the spool is wired in")
    }

    @Test("A stopped command keeps what the remote host already printed")
    func stoppedKeepsOutput() {
        let out = OutputCapture(headLimit: 1000, tailWindow: 64)
        out.append(Data("starting job\n".utf8))
        let err = OutputCapture(headLimit: 1000, tailWindow: 64)
        err.append(Data("warning: retrying\n".utf8))
        let text = SSHResult.stopped("⏱️ run_ssh: Command timed out after 30s on host.",
                                     stdout: out, stderr: err)
        #expect(text.hasPrefix("⏱️ run_ssh: Command timed out after 30s on host."))
        #expect(text.contains("--- output received before the stop ---\nstarting job"))
        #expect(text.contains("--- stderr before the stop ---\nwarning: retrying"))
    }

    @Test("A stop with no output is just the reason, with no empty sections")
    func stoppedSilent() {
        let text = SSHResult.stopped("🛑 run_ssh: Command cancelled by the user.",
                                     stdout: OutputCapture(), stderr: OutputCapture())
        #expect(text == "🛑 run_ssh: Command cancelled by the user.")
        #expect(!text.contains("---"))
    }
}
