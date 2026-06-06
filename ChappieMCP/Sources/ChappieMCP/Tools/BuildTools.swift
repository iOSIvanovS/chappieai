// BuildTools.swift
//
// WHY THIS FILE:
// Implements build_project, run_tests, read_build_log tools for all supported dev environments.
// Routes each command to the correct shell tool based on the active DevEnvironment.
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

import Foundation

/// Max wait time for build/test processes. 5 minutes is enough for any real build.
private let kBuildTimeoutSeconds: Double = 300

// MARK: - DataBox

/// Thread-safe data accumulator for parallel pipe reading.
///
/// WHY: Swift 6 forbids mutating `var` captured in concurrent @Sendable closures.
/// Solution: reference type with NSLock — closures capture a reference (allowed).
private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func set(_ newData: Data) {
        lock.withLock { data = newData }
    }

    func get() -> Data {
        lock.withLock { data }
    }
}

// MARK: - BuildTools

/// Build and test tools router. Delegates to env-specific shell commands.
final class BuildTools: Sendable {

    private let projectPath: String
    private let environment: DevEnvironment

    /// Shared log file path — written by build/test, read by read_build_log.
    private var buildLogPath: String {
        projectPath + "/.build_log.txt"
    }

    init(projectPath: String, environment: DevEnvironment) {
        self.projectPath = projectPath
        self.environment = environment
    }

    // MARK: - Public tools

    func build() async -> ToolResult {
        switch environment {
        case .xcode:
            return await runXcodebuild(
                args: ["-project", xcodeProjectName(), "-scheme", xcodeAppScheme(),
                       "-configuration", "Debug", "-destination", "platform=macOS", "build"],
                label: "build_project"
            )
        case .nodejs:
            return await runShell("npm run build", label: "build_project")
        case .go:
            return await runShell("go build ./...", label: "build_project")
        case .rust:
            return await runShell("cargo build", label: "build_project")
        case .java:
            return await runShell(mavenOrGradle(maven: "mvn compile", gradle: "gradle build"), label: "build_project")
        case .kotlin:
            return await runShell(gradleWrapper("build"), label: "build_project")
        case .flutter:
            return await runShell("flutter build", label: "build_project")
        case .dotnet:
            return await runShell("dotnet build", label: "build_project")
        case .python, .reacttypescript, .unknown:
            // Python and React/TS have no compile step — build_project is not in their specificTools.
            return .failure("build_project is not available for \(environment.rawValue) environment.")
        }
    }

    func runTests(target: String?) async -> ToolResult {
        switch environment {
        case .xcode:
            var args = ["-project", xcodeProjectName(), "-scheme", xcodeTestScheme(),
                        "-destination", "platform=macOS", "test"]
            if let target, !target.isEmpty {
                args.append(contentsOf: ["-only-testing", target])
            }
            return await runXcodebuild(args: args, label: "run_tests")
        case .nodejs:
            let pattern = target.map { " -- \($0)" } ?? ""
            return await runShell("npm test\(pattern)", label: "run_tests")
        case .python:
            let pattern = target ?? ""
            let cmd = pattern.isEmpty ? "python -m pytest" : "python -m pytest \(pattern)"
            return await runShell(cmd, label: "run_tests")
        case .go:
            let pkg = target ?? "./..."
            return await runShell("go test \(pkg)", label: "run_tests")
        case .rust:
            let filter = target.map { " \($0)" } ?? ""
            return await runShell("cargo test\(filter)", label: "run_tests")
        case .java:
            let cls = target.map { " -Dtest=\($0)" } ?? ""
            return await runShell(mavenOrGradle(maven: "mvn test\(cls)", gradle: "gradle test\(cls)"), label: "run_tests")
        case .kotlin:
            let cls = target.map { " --tests \($0)" } ?? ""
            return await runShell(gradleWrapper("test\(cls)"), label: "run_tests")
        case .flutter:
            let file = target.map { " \($0)" } ?? ""
            return await runShell("flutter test\(file)", label: "run_tests")
        case .reacttypescript:
            let pattern = target.map { " \($0)" } ?? ""
            return await runShell("npm test\(pattern)", label: "run_tests")
        case .dotnet:
            let proj = target.map { " \($0)" } ?? ""
            return await runShell("dotnet test\(proj)", label: "run_tests")
        case .unknown:
            return .failure("run_tests is not available: dev environment is not set.")
        }
    }

    func readLastLog() async -> ToolResult {
        let logURL = URL(fileURLWithPath: buildLogPath)
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return .failure("Build log not found. Run build_project or run_tests first.")
        }
        return .success(content)
    }

    // MARK: - Xcode helpers

    /// Finds the first .xcodeproj in the project directory.
    private func xcodeProjectName() -> String {
        let url = URL(fileURLWithPath: projectPath)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: projectPath) {
            if let proj = items.first(where: { $0.hasSuffix(".xcodeproj") }) {
                return proj
            }
        }
        return url.lastPathComponent + ".xcodeproj"
    }

    /// Derives the main app scheme name from the project file name.
    private func xcodeAppScheme() -> String {
        xcodeProjectName().replacingOccurrences(of: ".xcodeproj", with: "")
    }

    /// Derives the test scheme: AppName + "Tests" (e.g. "ChappieCoreTests").
    private func xcodeTestScheme() -> String {
        xcodeAppScheme() + "CoreTests"
    }

    // MARK: - Java/Kotlin helpers

    /// Returns the right command depending on whether Maven or Gradle is present.
    private func mavenOrGradle(maven: String, gradle: String) -> String {
        let hasPom = FileManager.default.fileExists(atPath: projectPath + "/pom.xml")
        return hasPom ? maven : gradle
    }

    /// Uses gradlew wrapper if available, falls back to system gradle.
    private func gradleWrapper(_ task: String) -> String {
        let wrapper = projectPath + "/gradlew"
        let exe = FileManager.default.fileExists(atPath: wrapper) ? "./gradlew" : "gradle"
        return "\(exe) \(task)"
    }

    // MARK: - Shell runner

    /// Runs a generic shell command, saves log, returns summary.
    private func runShell(_ command: String, label: String) async -> ToolResult {
        print("[ChappieMCP] 🔨 \(label): \(command)")
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(
                    executable: "/bin/sh",
                    args: ["-c", command],
                    workingDirectory: self.projectPath,
                    label: label
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Xcode runner

    private func runXcodebuild(args: [String], label: String) async -> ToolResult {
        print("[ChappieMCP] 🔨 \(label): xcodebuild \(args.joined(separator: " "))")
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(
                    executable: "/usr/bin/xcodebuild",
                    args: args,
                    workingDirectory: self.projectPath,
                    label: label
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Core process runner

    /// Runs a process with timeout, parallel pipe reading, log saving.
    ///
    /// WHY PARALLEL PIPE READING:
    /// readDataToEndOfFile() AFTER waitUntilExit() = deadlock if output > 64KB.
    /// The process blocks writing to the full pipe; waitUntilExit() waits for exit.
    /// Fix: read in parallel threads, then waitUntilExit().
    private func runProcess(
        executable: String,
        args: [String],
        workingDirectory: String,
        label: String
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

        // Timeout guard — kills process if it hangs.
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

        // Parallel pipe reading to prevent deadlock.
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
            let msg = "⏱️ \(label) timed out after \(Int(kBuildTimeoutSeconds))s and was terminated. Try again or check manually."
            saveLog(msg, label: label, command: ([executable] + args).joined(separator: " "))
            return .failure(msg)
        }

        let stdout = String(data: stdoutBox.get(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.get(), encoding: .utf8) ?? ""
        let fullOutput = stdout + (stderr.isEmpty ? "" : "\n--- STDERR ---\n" + stderr)

        saveLog(fullOutput, label: label, command: ([executable] + args).joined(separator: " "))

        let exitCode = process.terminationStatus

        if exitCode == 0 {
            let summary = extractSummary(from: fullOutput)
            return .success("✅ Success (\(elapsed)s)\n\(summary)\n\nFull log: read_build_log")
        } else {
            let errors = extractErrors(from: fullOutput)
            return .failure("❌ Failed (exit \(exitCode), \(elapsed)s)\n\n\(errors)\n\nFull log: read_build_log")
        }
    }

    // MARK: - Log helpers

    private func saveLog(_ output: String, label: String, command: String) {
        let header = """
        === ChappieMCP Build Log ===
        Tool:    \(label)
        Env:     \(environment.rawValue)
        Command: \(command)
        Time:    \(Date())
        ============================

        """
        try? (header + output).write(toFile: buildLogPath, atomically: true, encoding: .utf8)
    }

    /// Extracts summary lines (status, warnings, test stats) from build output.
    private func extractSummary(from output: String) -> String {
        let keywords = ["BUILD SUCCEEDED", "BUILD FAILED", "TEST SUCCEEDED", "TEST FAILED",
                        "warning:", "Executed", "PASSED", "FAILED", "passed", "failed"]
        let lines = output.components(separatedBy: "\n")
            .filter { line in keywords.contains { line.contains($0) } }
        return lines.isEmpty ? "Completed without warnings." : lines.prefix(20).joined(separator: "\n")
    }

    /// Extracts error lines from build output for a concise failure report.
    ///
    /// WHY: full xcodebuild/compiler output can be 1000+ lines.
    /// AI only needs the errors — not the noise.
    private func extractErrors(from output: String) -> String {
        let keywords = ["error:", "Error:", "BUILD FAILED", "FAILED", "warning:"]
        let lines = output.components(separatedBy: "\n")
            .filter { line in keywords.contains { line.contains($0) } }
        if lines.isEmpty {
            return "Error details:\n" + output.components(separatedBy: "\n").suffix(30).joined(separator: "\n")
        }
        return lines.prefix(50).joined(separator: "\n")
    }
}
