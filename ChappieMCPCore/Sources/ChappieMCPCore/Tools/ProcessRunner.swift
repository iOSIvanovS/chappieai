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

    /// PATH for every child process. It must contain /bin and the sbin dirs: build scripts and git
    /// hooks call sleep, cat, rm, ls from /bin, and a PATH without it fails with "command not found".
    static let toolSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:/usr/local/go/bin"

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
        let processExited = ExitFlag()
        let readers = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, stdoutBox), (stderrPipe, stderrBox)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                box.set(readUntilEndOrAbandoned(fd: pipe.fileHandleForReading.fileDescriptor, exit: processExited))
                readers.leave()
            }
        }

        exited.wait()
        processExited.set()
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

// MARK: - Pipe reading

/// Set once the child process has exited.
final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var exitedAt: Date?

    func set() { lock.withLock { if exitedAt == nil { exitedAt = Date() } } }
    var secondsSinceExit: TimeInterval? { lock.withLock { exitedAt.map { Date().timeIntervalSince($0) } } }
}

/// How long the reader keeps waiting for end-of-file after the process itself has exited.
/// Output the process wrote is already in the pipe by then, so this only has to cover the reader
/// draining it. A longer wait would only serve a stray grandchild that holds the pipe open.
let pipeDrainGrace: TimeInterval = 1.5

/// Reads a pipe until EOF, but gives up `pipeDrainGrace` seconds after the process exited.
///
/// WHY NOT readDataToEndOfFile():
/// EOF arrives only when EVERY holder of the write end has closed it. A build daemon that outlived
/// the build (testmanagerd, a compiler server, `cmd &`) keeps the pipe open, so a blocking read
/// never returned: the process was long dead, yet Stop and the timeout "did nothing" and the
/// tool hung until the whole watchdog expired. Polling with a short timeout lets the reader notice
/// that the process is gone.
func readUntilEndOrAbandoned(fd: Int32, exit: ExitFlag) -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 100)
        if ready < 0 {
            if errno == EINTR { continue }
            return result
        }
        if ready == 0 {
            if let waited = exit.secondsSinceExit, waited >= pipeDrainGrace { return result }
            continue
        }
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            result.append(buffer, count: count)
        } else if count == 0 {
            return result
        } else if errno != EINTR && errno != EAGAIN {
            return result
        }
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
