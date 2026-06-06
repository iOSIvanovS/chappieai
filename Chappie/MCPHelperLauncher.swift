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
// socket path, and dev environment. Helper should not independently decide — simplifies
// diagnostics and allows centralized changes.
//
// LIFECYCLE:
// 1. ChappieApp.onAppear → MCPHelperLauncher.shared.launch(workspacePath:environment:)
// 2. Launcher starts Process with arguments: [workspacePath, socketPath, envRawValue]
// 3. MCPToolBridge uses the same socketPath to connect
// 4. On Chappie.app exit → terminateHelper() kills child process
//
// WHY @Observable, NOT ObservableObject:
// In Swift 6 / macOS 26, @Observable macro is preferred.
// It doesn't require Combine and works natively with @MainActor without warnings.
//
// IMPORTANT — stdout/stderr via Pipe, NOT FileHandle.standardOutput:
// Passing FileHandle.standardOutput directly to the child process
// causes PTY errors (ErrorCode: 7, Errno: 6 "Device not configured") on macOS 26.5.
// Using Pipe isolates the child's output from the parent's PTY entirely.

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
    private var currentWorkspacePath: String?
    private var currentEnvironment: DevEnvironment = .unknown

    // MARK: - Init

    private init() {
        socketPath = "/tmp/com.chappie.mcp.sock"
    }

    // MARK: - Public Interface

    /// Launches ChappieMCP helper with the given workspace path and dev environment.
    ///
    /// DOUBLE-LAUNCH SAFETY:
    /// If helper is already running with the same path AND same environment — do nothing.
    /// If either changed — restart.
    func launch(workspacePath: String? = nil, environment: DevEnvironment = .unknown) {
        let path = workspacePath ?? FileManager.default.currentDirectoryPath

        if let process = helperProcess, process.isRunning,
           currentWorkspacePath == path, currentEnvironment == environment {
            print("[MCPHelperLauncher] ℹ️ Helper already running for: \(path) [\(environment.rawValue)]")
            return
        }

        if let process = helperProcess, process.isRunning {
            print("[MCPHelperLauncher] 🔄 Restarting helper: \(path) [\(environment.rawValue)]")
            process.terminate()
            helperProcess = nil
        }

        startHelper(workspacePath: path, environment: environment)
    }

    /// Restarts helper with a new workspace path and optional dev environment.
    func restartWithWorkspace(_ url: URL, environment: DevEnvironment = .unknown) {
        launch(workspacePath: url.path, environment: environment)
    }

    func terminateHelper() {
        guard let process = helperProcess, process.isRunning else { return }
        print("[MCPHelperLauncher] 🛑 Terminating ChappieMCP helper")
        process.terminate()
        helperProcess = nil
        status = .stopped
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Private Launch Logic

    private func startHelper(workspacePath: String, environment: DevEnvironment) {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP") else {
            let fallbackURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("ChappieMCP")

            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                startProcess(at: fallbackURL, workspacePath: workspacePath, environment: environment)
            } else {
                print("[MCPHelperLauncher] ❌ ChappieMCP binary not found in bundle!")
                status = .failed("Binary not found in bundle")
            }
            return
        }

        startProcess(at: helperURL, workspacePath: workspacePath, environment: environment)
    }

    private func startProcess(at url: URL, workspacePath: String, environment: DevEnvironment) {
        let process = Process()
        process.executableURL = url
        // argv[1] = workspacePath, argv[2] = socketPath, argv[3] = devEnvironment rawValue
        process.arguments = [workspacePath, socketPath, environment.rawValue]

        // Use Pipe instead of FileHandle.standardOutput/standardError.
        // WHY: passing FileHandle.standardOutput directly causes PTY errors on macOS 26.5.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { print("[ChappieMCP] \(trimmed)") }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
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
                // Code 15 = SIGTERM — intentional termination, that's normal.
                if code != 15 {
                    self.status = .crashed(code: Int(code))
                    self.helperProcess = nil
                }
            }
        }

        do {
            try process.run()
            helperProcess = process
            currentWorkspacePath = workspacePath
            currentEnvironment = environment
            status = .running
            print("[MCPHelperLauncher] ✅ ChappieMCP started (PID: \(process.processIdentifier))")
            print("[MCPHelperLauncher] 📁 Workspace: \(workspacePath)")
            print("[MCPHelperLauncher] 🔌 Socket:    \(socketPath)")
            print("[MCPHelperLauncher] 🛠️  Env:       \(environment.rawValue)")
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
