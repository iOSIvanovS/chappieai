// ProcessRunner.swift
//
// One place that runs a child process for the helper's tools (build, git, document converters).
//
// WHY SHARED:
// Build, git and the PDF converter each had their own Process code, and none of them reacted
// to cancellation. Now the runner is the single owner of: parallel pipe reading (no 64 KB pipe
// deadlock), the optional timeout, and "stop the whole process tree when the caller is
// cancelled". When the app's Stop button closes the socket, MCPHTTPServer cancels the tool's
// Task, and the cancellation lands here.
//
// WHY `cancellable`:
// Mutating git commands (commit, push, ...) must not be killed halfway: that can leave
// index.lock or a half-applied state behind. They pass cancellable: false and always finish.

import Foundation

struct ProcessRun: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    /// Why the runner stopped the process, nil when it ended on its own.
    let stopReason: ProcessCanceller.Reason?
    /// Set when the process could not be started at all.
    let launchError: String?

    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

enum ProcessRunner {

    static func run(
        executable: String,
        args: [String],
        workingDirectory: String? = nil,
        environment: [String: String],
        timeout: TimeInterval? = nil,
        cancellable: Bool = true
    ) async -> ProcessRun {
        let canceller = ProcessCanceller()

        let work: @Sendable () async -> ProcessRun = {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runBlocking(
                        executable: executable,
                        args: args,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        timeout: timeout,
                        canceller: canceller
                    ))
                }
            }
        }

        guard cancellable else { return await work() }
        return await withTaskCancellationHandler {
            await work()
        } onCancel: {
            canceller.stop(.cancelled)
        }
    }

    // MARK: - Blocking part (runs on a GCD thread)

    private static func runBlocking(
        executable: String,
        args: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeout: TimeInterval?,
        canceller: ProcessCanceller
    ) -> ProcessRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRun(stdout: Data(), stderr: Data(), exitCode: -1, stopReason: nil,
                              launchError: error.localizedDescription)
        }
        // A Stop that arrived before launch finished is applied here.
        canceller.attach(pid: process.processIdentifier)

        let timeoutItem = timeout.map { seconds in
            let item = DispatchWorkItem { canceller.stop(.timedOut) }
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }

        // Read both pipes in parallel while waiting: a full pipe would block the child forever.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readers = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, stdoutBox), (stderrPipe, stderrBox)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }

        exited.wait()
        timeoutItem?.cancel()
        readers.wait()

        return ProcessRun(
            stdout: stdoutBox.get(),
            stderr: stderrBox.get(),
            exitCode: process.terminationStatus,
            stopReason: canceller.stopReason,
            launchError: nil
        )
    }
}

// MARK: - DataBox

/// Thread-safe data holder for the parallel pipe readers (Swift 6 forbids sharing a mutable var).
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func set(_ newData: Data) { lock.withLock { data = newData } }
    func get() -> Data { lock.withLock { data } }
}
