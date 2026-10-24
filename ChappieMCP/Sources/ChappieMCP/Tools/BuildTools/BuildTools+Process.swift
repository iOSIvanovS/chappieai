// BuildTools+Process.swift
//
// WHY THIS FILE:
// Runs build and test commands through the shared ProcessRunner and turns the outcome into a
// ToolResult for the AI. The runner owns pipe reading, the timeout and cancellation (Stop in
// the app kills the whole xcodebuild/test process tree), this file owns the log and the summary.
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

extension BuildTools {

    func runShell(_ command: String, label: String, workingDirectory: String, env: DevEnvironment) async -> ToolResult {
        print("[ChappieMCP] 🔨 \(label): \(command)")
        return await runProcess(
            executable: "/bin/sh",
            args: ["-c", command],
            workingDirectory: workingDirectory,
            label: label,
            env: env
        )
    }

    func runXcodebuild(args: [String], label: String, workingDirectory: String, env: DevEnvironment) async -> ToolResult {
        print("[ChappieMCP] 🔨 \(label): xcodebuild \(args.joined(separator: " "))")
        return await runProcess(
            executable: "/usr/bin/xcodebuild",
            args: args,
            workingDirectory: workingDirectory,
            label: label,
            env: env
        )
    }

    /// Runs a process with timeout, log saving and cancellation.
    func runProcess(
        executable: String,
        args: [String],
        workingDirectory: String,
        label: String,
        env: DevEnvironment
    ) async -> ToolResult {
        let startTime = Date()
        let command = ([executable] + args).joined(separator: " ")

        let run = await ProcessRunner.run(
            executable: executable,
            args: args,
            workingDirectory: workingDirectory,
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin/swift:/usr/local/go/bin",
                "LANG": "en_US.UTF-8",
                "NSUnbufferedIO": "YES"
            ],
            timeout: kBuildTimeoutSeconds
        )

        if let launchError = run.launchError {
            return .failure("Failed to launch \(executable): \(launchError)")
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))

        switch run.stopReason {
        case .timedOut:
            let msg = "⏱️ \(label) timed out after \(Int(kBuildTimeoutSeconds))s and was terminated."
            saveLog(msg, label: label, command: command, env: env)
            return .failure(msg)
        case .cancelled:
            // The app pressed Stop: the process tree is already being shut down.
            print("[ChappieMCP] 🛑 \(label) cancelled after \(elapsed)s")
            let msg = "🛑 \(label) was cancelled after \(elapsed)s; its processes were stopped."
            saveLog(msg, label: label, command: command, env: env)
            return .failure(msg)
        case nil:
            break
        }

        let stdout = run.stdoutText
        let stderr = run.stderrText
        let fullOutput = stdout + (stderr.isEmpty ? "" : "\n--- STDERR ---\n" + stderr)

        saveLog(fullOutput, label: label, command: command, env: env)

        if run.exitCode == 0 {
            let summary = extractSummary(from: fullOutput)
            return .success("✅ Success (\(elapsed)s)\n\(summary)\n\nFull log: read_build_log")
        } else {
            // WHY full log inline: AI should not need a second tool call to diagnose failures.
            let errors = extractErrors(from: fullOutput)
            let logSnippet = fullOutput.components(separatedBy: "\n").suffix(100).joined(separator: "\n")
            return .failure("❌ Failed (exit \(run.exitCode), \(elapsed)s)\n\n--- Errors ---\n\(errors)\n\n--- Last 100 lines ---\n\(logSnippet)")
        }
    }
}
