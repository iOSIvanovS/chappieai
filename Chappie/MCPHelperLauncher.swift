// MCPHelperLauncher.swift
// Chappie
//
// WHY THIS FILE:
// Manages the lifecycle of the ChappieMCP child process.
//
// SOCKET PATH ARCHITECTURE:
// Socket is placed in /tmp/ — standard path accessible to all processes
// without sandbox restrictions (sandbox removed from project).
//
// WHY WE PASS ARGUMENTS INSTEAD OF HARDCODING IN HELPER:
// Parent (Chappie.app) is the single source of truth about workspace path,
// socket path, and project env map. Helper should not independently decide.
//
// LIFECYCLE:
// 1. ChappieApp.onAppear → MCPHelperLauncher.shared.launch(workspacePath:projectEnvMap:)
// 2. Launcher starts Process with arguments: [workspacePath, socketPath, projectEnvMapJSON]
// 3. MCPToolBridge uses the same socketPath to connect
// 4. On Chappie.app exit → terminateHelper() kills child process
//
// PROJECT ENV MAP:
// JSON string {"ProjectName": "envRawValue", ...} passed as argv[3].
// MCP uses it to route build_project/run_tests to the correct env per project.
// Launcher restarts the helper whenever the map changes (project added/removed/env changed).
//
// WHY @Observable, NOT ObservableObject:
// In Swift 6 / macOS 26, @Observable macro is preferred.
// It doesn't require Combine and works natively with @MainActor without warnings.
//
// IMPORTANT — stdout/stderr via Pipe, NOT FileHandle.standardOutput:
// Passing FileHandle.standardOutput directly to the child process
// causes PTY errors (ErrorCode: 7, Errno: 6 "Device not configured") on macOS 26.5.
// Using Pipe isolates the child's output from the parent's PTY entirely.
//
// PIPE LEAK PREVENTION:
// readabilityHandler must be explicitly set to nil on both pipes before the process
// is terminated — otherwise the GCD read sources are never cancelled and the Pipe
// file descriptors remain open, leaking one FD pair per restart.

import Foundation
import AppKit
import ChappieCore
import Observation

/// Singleton for managing the ChappieMCP child process.
///
/// Why @MainActor: all Process operations and state updates
/// must happen on the main thread to avoid data races.
@MainActor
@Observable
final class MCPHelperLauncher {

    // MARK: - Singleton

    static let shared = MCPHelperLauncher()

    // MARK: - State

    var status: HelperStatus = .notStarted

    private(set) var socketPath: String = ""

    private var helperProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var currentWorkspacePath: String?
    private var currentProjectEnvMap: [String: String] = [:]

    // MARK: - Init

    private init() {
        socketPath = "/tmp/com.chappie.mcp.sock"
    }

    // MARK: - Public Interface

    /// Launches ChappieMCP helper with the given workspace path and project→env map.
    ///
    /// DOUBLE-LAUNCH SAFETY:
    /// If helper is already running with the same path AND same map — do nothing.
    /// If either changed — restart.
    func launch(workspacePath: String? = nil, projectEnvMap: [String: String] = [:]) {
        let path = workspacePath ?? FileManager.default.currentDirectoryPath

        if let process = helperProcess, process.isRunning,
           currentWorkspacePath == path, currentProjectEnvMap == projectEnvMap {
            print("[MCPHelperLauncher] ℹ️ Helper already running for: \(path) \(projectEnvMap)")
            return
        }

        if helperProcess != nil {
            print("[MCPHelperLauncher] 🔄 Restarting helper: \(path) \(projectEnvMap)")
            teardownCurrentProcess()
        }

        startHelper(workspacePath: path, projectEnvMap: projectEnvMap)
    }

    /// Restarts helper with a new workspace path and project→env map.
    func restartWithWorkspace(_ url: URL, projectEnvMap: [String: String] = [:]) {
        launch(workspacePath: url.path, projectEnvMap: projectEnvMap)
    }

    func terminateHelper() {
        guard helperProcess != nil else { return }
        print("[MCPHelperLauncher] 🛑 Terminating ChappieMCP helper")
        teardownCurrentProcess()
        status = .stopped
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Private Teardown

    /// Cleanly tears down the current process: cancels pipe handlers FIRST, then terminates.
    /// WHY pipes first: if we terminate before clearing readabilityHandler, the GCD read
    /// source fires one last time on the closed FD and then leaks — never getting deallocated.
    private func teardownCurrentProcess() {
        // Cancel GCD read sources before terminating — prevents FD leaks.
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        helperProcess?.terminate()
        helperProcess = nil
    }

    // MARK: - Private Launch Logic

    private func startHelper(workspacePath: String, projectEnvMap: [String: String]) {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP") else {
            let fallbackURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("ChappieMCP")

            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                startProcess(at: fallbackURL, workspacePath: workspacePath, projectEnvMap: projectEnvMap)
            } else {
                print("[MCPHelperLauncher] ❌ ChappieMCP binary not found in bundle!")
                status = .failed("Binary not found in bundle")
            }
            return
        }

        startProcess(at: helperURL, workspacePath: workspacePath, projectEnvMap: projectEnvMap)
    }

    private func startProcess(at url: URL, workspacePath: String, projectEnvMap: [String: String]) {
        // Serialize map to JSON for argv[3].
        let mapJSON: String
        if let data = try? JSONEncoder().encode(projectEnvMap),
           let str = String(data: data, encoding: .utf8) {
            mapJSON = str
        } else {
            mapJSON = "{}"
        }

        let process = Process()
        process.executableURL = url
        // argv[1] = workspacePath, argv[2] = socketPath, argv[3] = projectEnvMap JSON
        process.arguments = [workspacePath, socketPath, mapJSON]

        // Use Pipe instead of FileHandle.standardOutput/standardError.
        // WHY: passing FileHandle.standardOutput directly causes PTY errors on macOS 26.5.
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { print("[ChappieMCP] \(trimmed)") }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { print("[ChappieMCP:err] \(trimmed)") }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = terminatedProcess.terminationStatus
                print("[MCPHelperLauncher] ⚠️ Helper exited with code: \(code)")

                // Always clear helperProcess if it's the same process that just exited.
                // WHY: previously we skipped nil-ing on code==15 (SIGTERM), which meant
                // restarted processes were never released from memory.
                if self.helperProcess === terminatedProcess {
                    self.helperProcess = nil
                }

                // Code 15 = SIGTERM — intentional termination (restart or quit), not a crash.
                if code != 15 {
                    self.status = .crashed(code: Int(code))
                }
            }
        }

        do {
            try process.run()
            helperProcess = process
            stdoutPipe = outPipe
            stderrPipe = errPipe
            currentWorkspacePath = workspacePath
            currentProjectEnvMap = projectEnvMap
            status = .running
            print("[MCPHelperLauncher] ✅ ChappieMCP started (PID: \(process.processIdentifier))")
            print("[MCPHelperLauncher] 📁 Workspace: \(workspacePath)")
            print("[MCPHelperLauncher] 🔌 Socket:    \(socketPath)")
            print("[MCPHelperLauncher] 🗺️  Projects:  \(projectEnvMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        } catch {
            print("[MCPHelperLauncher] ❌ Failed to start helper: \(error)")
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - HelperStatus

enum HelperStatus: Equatable {
    case notStarted
    case running
    case stopped
    case failed(String)
    case crashed(code: Int)

    var description: String {
        switch self {
        case .notStarted:        return "Not started"
        case .running:           return "Running"
        case .stopped:           return "Stopped"
        case .failed(let msg):   return "Error: \(msg)"
        case .crashed(let code): return "Crashed (code \(code))"
        }
    }
}
