// MCPHelperLauncher.swift
// Chappie
//
// WHY THIS FILE:
// Manages the lifecycle of the ChappieMCP child process.
//
// SOCKET PATH ARCHITECTURE:
// Socket is placed in /tmp/ — standard path accessible to all processes
// without sandbox restrictions (sandbox removed from project).
// Path is computed once in init() and stored as a constant.
//
// WHY WE PASS PATH VIA ARGUMENT INSTEAD OF HARDCODING IN HELPER:
// Parent (Chappie.app) is the single source of truth about the socket path.
// Helper should not independently decide on file paths — simplifies diagnostics
// and allows centralized path changes.
//
// LIFECYCLE:
// 1. ChappieApp.onAppear → MCPHelperLauncher.shared.launch(workspacePath:)
// 2. Launcher takes socketPath (computed in init)
// 3. Starts Process with arguments: [workspacePath, socketPath]
// 4. MCPToolBridge uses the same socketPath to connect
// 5. On Chappie.app exit → terminateHelper() kills child process
//
// WHY @Observable, NOT ObservableObject:
// In Swift 6 / macOS 26, @Observable macro system is preferred.
// It doesn't require Combine and works natively with @MainActor without warnings.
//
// IMPORTANT — stdout/stderr via Pipe, NOT FileHandle.standardOutput:
// Passing FileHandle.standardOutput/standardError directly to the child process
// causes PTY errors (ErrorCode: 7, Errno: 6 "Device not configured") on macOS 26.5.
// Using Pipe isolates the child's output from the parent's PTY entirely.
// We read logs from the pipe asynchronously and forward them via print().

import Foundation
import AppKit
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

    /// Current helper status — for UI display.
    var status: HelperStatus = .notStarted

    /// Path to Unix Domain Socket.
    ///
    /// WHY NOT lazy: @Observable macro is incompatible with lazy — it generates
    /// init accessor that cannot access backing storage (_socketPath).
    /// Compute path in init() and store as a regular property.
    private(set) var socketPath: String = ""

    /// Child process for ChappieMCP.
    private var helperProcess: Process?

    /// Workspace path the helper was launched with.
    private var currentWorkspacePath: String?

    // MARK: - Init

    private init() {
        socketPath = "/tmp/com.chappie.mcp.sock"
    }

    // MARK: - Public Interface

    /// Launches ChappieMCP helper with the given workspace path.
    ///
    /// DOUBLE-LAUNCH SAFETY:
    /// If helper is already running with the same path — do nothing.
    /// If path changed — restart.
    func launch(workspacePath: String? = nil) {
        let path = workspacePath ?? FileManager.default.currentDirectoryPath

        if let process = helperProcess, process.isRunning, currentWorkspacePath == path {
            print("[MCPHelperLauncher] ℹ️ Helper already running for: \(path)")
            return
        }

        if let process = helperProcess, process.isRunning {
            print("[MCPHelperLauncher] 🔄 Restarting helper for new workspace: \(path)")
            process.terminate()
            helperProcess = nil
        }

        startHelper(workspacePath: path)
    }

    /// Restarts helper with a new workspace path.
    /// Called from ChappieViewModel.setWorkspace() on project change.
    func restartWithWorkspace(_ url: URL) {
        launch(workspacePath: url.path)
    }

    /// Terminates the child process.
    /// Called from ChappieApp on application exit.
    func terminateHelper() {
        guard let process = helperProcess, process.isRunning else { return }
        print("[MCPHelperLauncher] 🛑 Terminating ChappieMCP helper")
        process.terminate()
        helperProcess = nil
        status = .stopped
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Private Launch Logic

    /// Finds the binary in bundle and launches it as a child process.
    private func startHelper(workspacePath: String) {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP") else {
            let fallbackURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("ChappieMCP")

            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                startProcess(at: fallbackURL, workspacePath: workspacePath)
            } else {
                print("[MCPHelperLauncher] ❌ ChappieMCP binary not found in bundle!")
                print("[MCPHelperLauncher] ℹ️ Expected path: \(fallbackURL.path)")
                print("[MCPHelperLauncher] ℹ️ Add ChappieMCP to Copy Files Build Phase → Helpers")
                status = .failed("Binary not found in bundle")
            }
            return
        }

        startProcess(at: helperURL, workspacePath: workspacePath)
    }

    /// Creates and starts the Process for the helper.
    private func startProcess(at url: URL, workspacePath: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = [workspacePath, socketPath]

        // Use Pipe instead of FileHandle.standardOutput/standardError.
        // WHY: passing FileHandle.standardOutput directly to the child process
        // causes PTY errors (ErrorCode: 7, Errno: 6) on macOS 26.5 beta.
        // Pipe completely isolates the child's I/O from the parent's PTY.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Forward child logs to parent's console asynchronously.
        // WHY async: reading synchronously would block the main thread.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                print("[ChappieMCP] \(trimmed)")
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                print("[ChappieMCP:err] \(trimmed)")
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = terminatedProcess.terminationStatus
                print("[MCPHelperLauncher] ⚠️ Helper exited with code: \(code)")

                // Code 15 = SIGTERM — we terminated it intentionally, that's normal.
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
            status = .running
            print("[MCPHelperLauncher] ✅ ChappieMCP helper started (PID: \(process.processIdentifier))")
            print("[MCPHelperLauncher] 📁 Workspace: \(workspacePath)")
            print("[MCPHelperLauncher] 🔌 Socket: \(socketPath)")
        } catch {
            print("[MCPHelperLauncher] ❌ Failed to start helper: \(error)")
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - HelperStatus

/// Helper lifecycle status.
///
/// Why enum instead of Bool: allows passing error details to UI
/// without additional properties.
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
