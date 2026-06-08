// MCPHelperLauncher.swift
// Chappie
//
// WHY THIS FILE:
// Manages the lifecycle of the ChappieMCP child process.
//
// CLI ARGUMENTS PASSED TO ChappieMCP:
// argv[1] = workspacePath  — workspace root (fallback path for git/build)
// argv[2] = socketPath     — Unix Domain Socket file path
// argv[3] = projectEnvMap  — JSON {"ProjectName": "envRawValue"} for build/test routing
// argv[4] = projectPathMap — JSON {"ProjectName": "/absolute/path"} for git routing
//
// WHY TWO MAPS:
// projectEnvMap routes build_project/run_tests to the correct dev environment.
// projectPathMap routes git_* tools to the correct working directory.
// Both are needed when multiple projects with different paths are attached.
//
// LIFECYCLE:
// 1. ChappieApp.onAppear → MCPHelperLauncher.shared.launch(workspacePath:projectEnvMap:projectPathMap:)
// 2. Launcher starts Process with arguments: [workspacePath, socketPath, envMapJSON, pathMapJSON]
// 3. MCPToolBridge uses the same socketPath to connect
// 4. On Chappie.app exit → terminateHelper() kills child process
//
// RESTART POLICY:
// Helper restarts whenever workspacePath, projectEnvMap, or projectPathMap changes.
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
    private var currentProjectPathMap: [String: String] = [:]

    // MARK: - Init

    private init() {
        socketPath = "/tmp/com.chappie.mcp.sock"
    }

    // MARK: - Public Interface

    /// Launches ChappieMCP helper with the given workspace path, env map, and path map.
    ///
    /// If helper is already running with identical arguments — does nothing.
    /// If any argument changed — restarts.
    func launch(workspacePath: String? = nil,
                projectEnvMap: [String: String] = [:],
                projectPathMap: [String: String] = [:]) {
        let path = workspacePath ?? FileManager.default.currentDirectoryPath

        if let process = helperProcess, process.isRunning,
           currentWorkspacePath == path,
           currentProjectEnvMap == projectEnvMap,
           currentProjectPathMap == projectPathMap {
            print("[MCPHelperLauncher] ℹ️ Helper already running for: \(path)")
            return
        }

        if helperProcess != nil {
            print("[MCPHelperLauncher] 🔄 Restarting helper: \(path)")
            teardownCurrentProcess()
        }

        startHelper(workspacePath: path, projectEnvMap: projectEnvMap, projectPathMap: projectPathMap)
    }

    /// Restarts helper with a new workspace URL, env map, and path map.
    func restartWithWorkspace(_ url: URL,
                              projectEnvMap: [String: String] = [:],
                              projectPathMap: [String: String] = [:]) {
        launch(workspacePath: url.path, projectEnvMap: projectEnvMap, projectPathMap: projectPathMap)
    }

    func terminateHelper() {
        guard helperProcess != nil else { return }
        print("[MCPHelperLauncher] 🛑 Terminating ChappieMCP helper")
        teardownCurrentProcess()
        status = .stopped
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Private Teardown

    /// Cancels pipe handlers FIRST, then terminates — prevents FD leaks.
    private func teardownCurrentProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        helperProcess?.terminate()
        helperProcess = nil
    }

    // MARK: - Private Launch Logic

    private func startHelper(workspacePath: String,
                             projectEnvMap: [String: String],
                             projectPathMap: [String: String]) {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP") else {
            let fallbackURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("ChappieMCP")

            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                startProcess(at: fallbackURL, workspacePath: workspacePath,
                             projectEnvMap: projectEnvMap, projectPathMap: projectPathMap)
            } else {
                print("[MCPHelperLauncher] ❌ ChappieMCP binary not found in bundle!")
                status = .failed("Binary not found in bundle")
            }
            return
        }

        startProcess(at: helperURL, workspacePath: workspacePath,
                     projectEnvMap: projectEnvMap, projectPathMap: projectPathMap)
    }

    private func startProcess(at url: URL,
                              workspacePath: String,
                              projectEnvMap: [String: String],
                              projectPathMap: [String: String]) {
        // Serialize both maps to JSON for argv[3] and argv[4].
        let envMapJSON  = jsonString(from: projectEnvMap)
        let pathMapJSON = jsonString(from: projectPathMap)

        let process = Process()
        process.executableURL = url
        // argv[1]=workspacePath, argv[2]=socketPath, argv[3]=envMap, argv[4]=pathMap
        process.arguments = [workspacePath, socketPath, envMapJSON, pathMapJSON]

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
            currentProjectPathMap = projectPathMap
            status = .running
            print("[MCPHelperLauncher] ✅ ChappieMCP started (PID: \(process.processIdentifier))")
            print("[MCPHelperLauncher] 📁 Workspace: \(workspacePath)")
            print("[MCPHelperLauncher] 🔌 Socket:    \(socketPath)")
            print("[MCPHelperLauncher] 🗺️  Envs:     \(projectEnvMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
            print("[MCPHelperLauncher] 📂 Paths:    \(projectPathMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        } catch {
            print("[MCPHelperLauncher] ❌ Failed to start helper: \(error)")
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func jsonString(from map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
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
