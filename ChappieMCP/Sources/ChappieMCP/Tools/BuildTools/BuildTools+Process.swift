// BuildTools+Process.swift
//
// WHY THIS FILE:
// Core process execution engine for build and test tools.
//
// PIPE DEADLOCK FIX (2025-07-11):
// process.waitUntilExit() + readDataToEndOfFile() AFTER it = deadlock.
// Pipe buffer is ~64KB. If xcodebuild writes more, it blocks waiting for reads.
// Fix: read stdout/stderr in parallel threads while waitUntilExit() runs.
//
// SWIFT 6 CONCURRENCY FIX (2025-07-11):
// Capturing `var` into @Sendable closures of different threads is illegal.
// Fix: DataBox class (@unchecked Sendable) with NSLock — closures capture a reference, not a var.
//
// TIMEOUT:
// xcodebuild sometimes hangs (especially on macOS 26 beta).
// DispatchWorkItem + process.terminate() kills it after kBuildTimeoutSeconds.
//
// XCODE-SPECIFIC NOTES:
// ChappieCoreTests is an Xcode Unit Test Bundle (target in Chappie.xcodeproj), NOT an SPM testTarget.
// So `swift test` doesn't know about it — only `xcodebuild test` with scheme ChappieCoreTests works.
//
// DESTINATION HISTORY (xcodebuild):
// ❌ "platform=macOS,arch=arm64"  — breaks on Intel
// ❌ "platform=macOS,arch=x86_64" — sometimes fails on macOS 26 beta
// ❌ "platform=macOS,name=Any Mac" — macOS 26 beta bug
// ✅ "platform=macOS"              — equivalent to "My Mac" in Xcode, Xcode picks arch

import Foundation

/// Max wait time for build/test processes. 5 minutes proved too short for some real
/// builds (clean builds, large test suites) — raised to 1 hour per user report of a
/// build that legitimately needed more than 300s and got killed with no data.
private let kBuildTimeoutSeconds: Double = 3600

// MARK: - DataBox

/// Thread-safe data accumulator for parallel pipe reading.
///
/// WHY: Swift 6 forbids mutating `var` captured in concurrent @Sendable closures.
/// Solution: reference type with NSLock — closures capture a reference (allowed).
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func set(_ newData: Data) {
        lock.withLock { data = newData }
    }

    func get() -> Data {
        lock.withLock { data }
    }
}

// MARK: - Process runners

extension BuildTools {

    func runShell(_ command: String, label: String, workingDirectory: String, env: DevEnvironment) async -> ToolResult {
        print("[ChappieMCP] 🔨 \(label): \(command)")
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(
                    executable: "/bin/sh",
                    args: ["-c", command],
                    workingDirectory: workingDirectory,
                    label: label,
                    env: env
                )
                continuation.resume(returning: result)
            }
        }
    }

    func runXcodebuild(args: [String], label: String, workingDirectory: String, env: DevEnvironment) async -> ToolResult {
        print("[ChappieMCP] 🔨 \(label): xcodebuild \(args.joined(separator: " "))")
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(
                    executable: "/usr/bin/xcodebuild",
                    args: args,
                    workingDirectory: workingDirectory,
                    label: label,
                    env: env
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Runs a process with timeout, parallel pipe reading, log saving.
    ///
    /// WHY PARALLEL PIPE READING:
    /// readDataToEndOfFile() AFTER waitUntilExit() = deadlock if output > 64KB.
    /// The process blocks writing to the full pipe; waitUntilExit() waits for exit.
    /// Fix: read in parallel threads, then waitUntilExit().
    func runProcess(
        executable: String,
        args: [String],
        workingDirectory: String,
        label: String,
        env: DevEnvironment
    ) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin/swift:/usr/local/go/bin",
            "LANG": "en_US.UTF-8",
            "NSUnbufferedIO": "YES"
        ]

        let startTime = Date()

        var timedOut = false
        let killWorkItem = DispatchWorkItem {
            if process.isRunning {
                print("[ChappieMCP] ⏱️ Timeout \(label) (\(Int(kBuildTimeoutSeconds))s) — terminating")
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .background).asyncAfter(
            deadline: .now() + kBuildTimeoutSeconds,
            execute: killWorkItem
        )

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            killWorkItem.cancel()
            return .failure("Failed to launch \(executable): \(error.localizedDescription)")
        }

        killWorkItem.cancel()
        readGroup.wait()

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))

        if timedOut {
            let msg = "⏱️ \(label) timed out after \(Int(kBuildTimeoutSeconds))s and was terminated."
            saveLog(msg, label: label, command: ([executable] + args).joined(separator: " "), env: env)
            return .failure(msg)
        }

        let stdout = String(data: stdoutBox.get(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.get(), encoding: .utf8) ?? ""
        let fullOutput = stdout + (stderr.isEmpty ? "" : "\n--- STDERR ---\n" + stderr)

        saveLog(fullOutput, label: label, command: ([executable] + args).joined(separator: " "), env: env)

        let exitCode = process.terminationStatus

        if exitCode == 0 {
            let summary = extractSummary(from: fullOutput)
            return .success("✅ Success (\(elapsed)s)\n\(summary)\n\nFull log: read_build_log")
        } else {
            // WHY full log inline: AI should not need a second tool call to diagnose failures.
            let errors = extractErrors(from: fullOutput)
            let logSnippet = fullOutput.components(separatedBy: "\n").suffix(100).joined(separator: "\n")
            return .failure("❌ Failed (exit \(exitCode), \(elapsed)s)\n\n--- Errors ---\n\(errors)\n\n--- Last 100 lines ---\n\(logSnippet)")
        }
    }
}
