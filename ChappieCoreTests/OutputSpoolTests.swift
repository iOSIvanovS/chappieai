// OutputSpoolTests.swift
// ChappieCoreTests
//
// A command that prints more than the command limit keeps its full output in a file; the model gets
// the beginning, the end, the path and a hint. The file must equal the real output, the exit code
// must survive, and the folder must not grow without bound.

import Testing
import Foundation
@testable import ChappieCore

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spool-tests-\(UUID().uuidString)", isDirectory: true)
}

private func fileText(_ summary: OutputSpool.Summary) -> String {
    String(decoding: (try? Data(contentsOf: summary.url)) ?? Data(), as: UTF8.self)
}

// MARK: - Capture + spool

@Suite("OutputSpool — capture side")
struct OutputSpoolCaptureTests {

    @Test("Small output never creates a file")
    func smallOutputNoFile() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = OutputCapture(headLimit: 1000, tailWindow: 64, spoolDirectory: dir, spoolThreshold: 500)
        capture.append(Data("hello\n".utf8))
        #expect(!capture.isSpooled)
        #expect(capture.closeSpool(tailBytes: 100) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("The file holds every byte, including what the head no longer stores")
    func fileHoldsEverything() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = OutputCapture(headLimit: 200, tailWindow: 64, spoolDirectory: dir, spoolThreshold: 100)
        var expected = ""
        for index in 0..<500 {
            let line = "line \(index)\n"
            expected += line
            capture.append(Data(line.utf8))
        }
        #expect(capture.isSpooled)
        #expect(capture.isTruncated)
        let summary = try #require(capture.closeSpool(tailBytes: 50))
        #expect(fileText(summary) == expected)
        #expect(summary.bytes == expected.utf8.count)
        #expect(summary.lines == 500)
        #expect(!summary.isIncomplete)
        #expect(summary.tailText.hasSuffix("line 499\n"))
        #expect(!summary.tailText.hasPrefix("ine"), "the tail starts at a line boundary")
    }

    @Test("The file is private to its owner")
    func filePermissions() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = OutputCapture(headLimit: 100, tailWindow: 16, spoolDirectory: dir, spoolThreshold: 10)
        capture.append(Data(String(repeating: "x", count: 50).utf8))
        let summary = try #require(capture.closeSpool(tailBytes: 10))
        let attrs = try FileManager.default.attributesOfItem(atPath: summary.url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test("The trailer the shell session appends is cut off the file")
    func trailerIsRemoved() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = OutputCapture(headLimit: 100, tailWindow: 256, spoolDirectory: dir, spoolThreshold: 50)
        capture.append(Data((String(repeating: "a\n", count: 100) + "EXIT_CODE:3\n___SENTINEL___\n").utf8))
        let summary = try #require(capture.closeSpool(trailerMarker: "EXIT_CODE:", tailBytes: 20))
        #expect(fileText(summary) == String(repeating: "a\n", count: 100))
        #expect(summary.lines == 100)
    }

    @Test("The size cap stops the file and says it is incomplete")
    func sizeCap() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = try #require(OutputSpool.create(in: dir, limit: 100))
        spool.write(Data(String(repeating: "x", count: 80).utf8))
        spool.write(Data(String(repeating: "y", count: 80).utf8))
        spool.write(Data(String(repeating: "z", count: 80).utf8))
        let summary = spool.finish(dropping: 0, droppedNewlines: 0, tailBytes: 10)
        #expect(summary.bytes == 100)
        #expect(summary.isIncomplete)
    }

    @Test("A file name never repeats and sits inside the given folder")
    func uniqueNames() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(OutputSpool.create(in: dir))
        let second = try #require(OutputSpool.create(in: dir))
        #expect(first.url != second.url)
        #expect(first.url.deletingLastPathComponent().path == dir.path)
    }

    @Test("Without a usable folder the capture works as before")
    func unusableFolderFallsBack() {
        let capture = OutputCapture(headLimit: 100, tailWindow: 16,
                                    spoolDirectory: URL(fileURLWithPath: "/dev/null/nope"), spoolThreshold: 10)
        capture.append(Data(String(repeating: "x", count: 500).utf8))
        #expect(!capture.isSpooled)
        #expect(capture.isTruncated)
        #expect(capture.text().hasSuffix(OutputGuard.truncationMarker(totalBytes: 500)))
    }
}

// MARK: - Cleanup

@Suite("OutputSpool — cleanup")
struct OutputSpoolCleanupTests {

    private func makeFile(_ dir: URL, name: String, bytes: Int, age: TimeInterval) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    @Test("Files older than a day are removed, fresh ones and foreign files stay")
    func ageCleanup() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try makeFile(dir, name: "old.log", bytes: 10, age: OutputSpool.maxAge + 60)
        let fresh = try makeFile(dir, name: "fresh.log", bytes: 10, age: 60)
        let foreign = try makeFile(dir, name: "keep.txt", bytes: 10, age: OutputSpool.maxAge + 60)
        OutputSpool.cleanup(dir, now: Date())
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path), "only .log files are ours")
    }

    @Test("A recent file survives the size limit: it may belong to a running command")
    func recentFileIsNotEvicted() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recent = try makeFile(dir, name: "recent.log", bytes: OutputSpool.maxFolderBytes + 1, age: 60)
        OutputSpool.cleanup(dir, now: Date())
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }
}

// MARK: - Notice text

@Suite("OutputSpool — notice for the model")
struct OutputSpoolNoticeTests {

    @Test("The notice carries size, path, both ends and search commands that work on that path")
    func noticeContent() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = OutputCapture(headLimit: 4000, tailWindow: 64, spoolDirectory: dir, spoolThreshold: 100)
        for index in 0..<2000 { capture.append(Data("row \(index)\n".utf8)) }
        let summary = try #require(capture.closeSpool(tailBytes: 60))
        let notice = OutputGuard.spillNotice(head: capture.headText, summary: summary)
        #expect(notice.contains(summary.url.path))
        #expect(notice.contains("2000 lines"))
        #expect(notice.contains("row 0\n"))
        #expect(notice.contains("row 1999"))
        #expect(notice.contains("grep -n"))
        #expect(notice.contains("middle is NOT shown"))
        #expect(!notice.contains("DATA NOT PASSED"))
        #expect(OutputGuard.apply(toolName: "run_terminal", output: notice) == notice, "the gate lets the notice through")
    }

    @Test("An incomplete file is announced as such")
    func incompleteNotice() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = try #require(OutputSpool.create(in: dir, limit: 10))
        spool.write(Data("0123456789abcdef".utf8))
        let summary = spool.finish(dropping: 0, droppedNewlines: 0, tailBytes: 10)
        let notice = OutputGuard.spillNotice(head: "0123456789", summary: summary)
        #expect(notice.contains("FILE IS INCOMPLETE"))
    }

    @Test("The beginning is cut at a line, never inside a character")
    func headCut() {
        let text = (0..<5000).map { "строка \($0)" }.joined(separator: "\n")
        let head = OutputGuard.edgeHead(of: text, maxBytes: 1000)
        #expect(head.utf8.count <= 1000)
        #expect(text.hasPrefix(head))
        #expect(!head.contains("\u{FFFD}"))
        #expect(text.dropFirst(head.count).hasPrefix("\n"))
    }
}

// MARK: - Real shell

@Suite("OutputSpool — shell session")
struct OutputSpoolShellTests {

    @Test("A command over the limit returns a notice, the file equals the real output, the exit code survives")
    func bigOutputThroughShell() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory(), spoolDirectory: dir)
        let result = await shell.run("seq 1 60000; exit_code=7; (exit $exit_code)", timeout: 60)
        #expect(result.exitCode == 7)
        #expect(result.output.contains("OUTPUT TOO LONG TO SHOW"))
        #expect(result.output.utf8.count < 40_000, "the model gets a short piece, not the stream")
        #expect(result.output.contains("60000"), "the end is shown")
        #expect(result.output.contains("\n1\n2\n3\n"), "the beginning is shown")

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        let content = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        let expected = (1...60000).map(String.init).joined(separator: "\n") + "\n"
        #expect(content == expected)
        #expect(!content.contains("EXIT_CODE"))
        #expect(OutputGuard.apply(toolName: "run_terminal", output: result.formatted) == result.formatted)
    }

    @Test("Output just under the limit stays inline and leaves no file")
    func underLimitInline() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory(), spoolDirectory: dir)
        let result = await shell.run("head -c 90000 /dev/zero | tr '\\0' 'a'; echo", timeout: 60)
        #expect(result.exitCode == 0)
        #expect(result.output.utf8.count == 90_000)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("Output that fits the limit but grew the stream past it with the trailer is returned whole")
    func borderlineInline() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory(), spoolDirectory: dir)
        let result = await shell.run("head -c 102390 /dev/zero | tr '\\0' 'a'", timeout: 60)
        #expect(result.exitCode == 0)
        #expect(result.output.utf8.count == 102_390)
        #expect(!result.output.contains("OUTPUT TOO LONG"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(files.isEmpty, "the file of a result that fit is removed")
    }

    @Test("A timeout on a command that already printed a lot still returns the file path")
    func timeoutKeepsPath() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = ShellSession(initialDirectory: NSTemporaryDirectory(), spoolDirectory: dir)
        let result = await shell.run("seq 1 60000; sleep 30", timeout: 3)
        #expect(result.exitCode == -1)
        #expect(result.output.contains("timed out"))
        #expect(result.output.contains(dir.path))
        #expect(result.output.contains("OUTPUT TOO LONG TO SHOW"))
    }
}
