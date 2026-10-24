// MCPHelperLauncher.swift
// Chappie
//
// WHY THIS FILE:
// Owns the lifecycle of the ChappieMCP child process.
//
// CLI ARGUMENTS PASSED TO ChappieMCP:
// argv[1] = workspacePath  — workspace root (may be empty: no folder chosen)
// argv[2] = socketPath     — Unix Domain Socket path, one per app instance (MCPSocket)
// argv[3] = projectEnvMap  — JSON {"ProjectName": "envRawValue"} for build/test routing
// argv[4] = projectPathMap — JSON {"ProjectName": "/absolute/path"} for git routing and path roots
//
// LIFECYCLE:
// - launch() starts the helper; "running" is only reported once the socket accepts connections.
// - Unexpected exit → restart with growing pauses (MCPRestartPolicy); after repeated quick
//   failures it gives up and reports `.failed` instead of looping silently.
// - A tool call that finds nobody listening asks recoverForToolCall() for an immediate restart.
// - The helper exits by itself when this app dies (it watches its parent), so a killed app
//   (Xcode "Stop") does not leave orphans. Sockets of dead app instances are removed at start-up.
//
// RESTART TRIGGERS: workspacePath, projectEnvMap or projectPathMap changed.
//
// PIPE LEAK PREVENTION:
// readabilityHandler must be set to nil on both pipes before the process goes away —
// otherwise the GCD read sources are never cancelled and one FD pair leaks per restart.

import Foundation
import AppKit
import ChappieCore
import Observation

@MainActor
@Observable
final class MCPHelperLauncher {

    // MARK: - Singleton

    static let shared = MCPHelperLauncher()

    // MARK: - State

    var status: HelperStatus = .notStarted

    private(set) var socketPath: String

    private var helperProcess: Process?
    private var helperStartedAt: Date?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var currentWorkspacePath: String = ""
    private var currentProjectEnvMap: [String: String] = [:]
    private var currentProjectPathMap: [String: String] = [:]

    /// False after terminateHelper(): an exit is then expected, not a crash to recover from.
    private var wantsRunning = false
    private var restartPolicy = MCPRestartPolicy()
    private var pendingRestart: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        socketPath = MCPSocket.currentProcessPath
        let removed = MCPSocket.removeStaleSockets()
        if !removed.isEmpty {
            print("[MCPHelperLauncher] 🧹 Removed \(removed.count) stale socket(s): \(removed.joined(separator: ", "))")
        }
    }

    // MARK: - Public Interface

    /// Launches ChappieMCP with the given workspace path, env map, and path map.
    /// Does nothing if a helper with identical arguments is already running; restarts otherwise.
    func launch(workspacePath: String? = nil,
                projectEnvMap: [String: String] = [:],
                projectPathMap: [String: String] = [:]) {
        // No workspace chosen → empty root. The launch directory used to be substituted here,
        // which is "/" under Xcode and turned the helper's path guard into a no-op.
        let path = workspacePath ?? ""
        wantsRunning = true

        if let process = helperProcess, process.isRunning,
           currentWorkspacePath == path,
           currentProjectEnvMap == projectEnvMap,
           currentProjectPathMap == projectPathMap {
            print("[MCPHelperLauncher] ℹ️ Helper already running for: \(path)")
            return
        }

        pendingRestart?.cancel()
        pendingRestart = nil
        if helperProcess != nil {
            print("[MCPHelperLauncher] 🔄 Restarting helper: \(path)")
            teardownCurrentProcess()
        }

        restartPolicy.reset()
        currentWorkspacePath = path
        currentProjectEnvMap = projectEnvMap
        currentProjectPathMap = projectPathMap
        startHelper()
    }

    func restartWithWorkspace(_ url: URL,
                              projectEnvMap: [String: String] = [:],
                              projectPathMap: [String: String] = [:]) {
        launch(workspacePath: url.path, projectEnvMap: projectEnvMap, projectPathMap: projectPathMap)
    }

    func terminateHelper() {
        wantsRunning = false
        pendingRestart?.cancel()
        pendingRestart = nil
        guard helperProcess != nil else { return }
        print("[MCPHelperLauncher] 🛑 Terminating ChappieMCP helper")
        teardownCurrentProcess()
        status = .stopped
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Called by the tool bridge when a call found nobody listening. Concurrent callers share
    /// one recovery so five parallel tool calls do not restart the helper five times.
    func recoverForToolCall() async {
        if let running = recoveryTask {
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRecovery()
        }
        recoveryTask = task
        await task.value
        recoveryTask = nil
    }

    // MARK: - Recovery

    private func performRecovery() async {
        if let process = helperProcess, process.isRunning, MCPSocket.canConnect(socketPath) { return }

        print("[MCPHelperLauncher] 🩹 Helper unreachable — restarting on demand")
        wantsRunning = true
        pendingRestart?.cancel()
        pendingRestart = nil
        if helperProcess != nil { teardownCurrentProcess() }
        restartPolicy.reset()
        startHelper()
        if helperProcess != nil { _ = await Self.waitForSocket(socketPath) }
    }

    // MARK: - Teardown

    /// Cancels pipe handlers FIRST, then terminates — prevents FD leaks. Clearing
    /// `helperProcess` before terminate() is what marks the coming exit as intentional.
    private func teardownCurrentProcess() {
        detachPipes()
        let process = helperProcess
        helperProcess = nil
        process?.terminate()
    }

    private func detachPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    // MARK: - Launch Logic

    private func startHelper() {
        let bundled = Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP")
        let fallback = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ChappieMCP")

        if let url = bundled {
            startProcess(at: url)
        } else if FileManager.default.fileExists(atPath: fallback.path) {
            startProcess(at: fallback)
        } else {
            print("[MCPHelperLauncher] ❌ ChappieMCP binary not found in bundle!")
            status = .failed("Binary not found in bundle")
        }
    }

    private func startProcess(at url: URL) {
        let process = Process()
        process.executableURL = url
        process.arguments = [currentWorkspacePath, socketPath,
                             jsonString(from: currentProjectEnvMap),
                             jsonString(from: currentProjectPathMap)]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = Self.logHandler(prefix: "[ChappieMCP]")
        errPipe.fileHandleForReading.readabilityHandler = Self.logHandler(prefix: "[ChappieMCP:err]")

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in self?.helperExited(terminated) }
        }

        do {
            try process.run()
        } catch {
            print("[MCPHelperLauncher] ❌ Failed to start helper: \(error)")
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            status = .failed(error.localizedDescription)
            return
        }

        helperProcess = process
        helperStartedAt = Date()
        stdoutPipe = outPipe
        stderrPipe = errPipe
        status = .starting
        print("[MCPHelperLauncher] ✅ ChappieMCP started (PID: \(process.processIdentifier))")
        print("[MCPHelperLauncher] 🔌 Socket: \(socketPath)")
        print("[MCPHelperLauncher] 📁 Workspace: \(currentWorkspacePath.isEmpty ? "(none)" : currentWorkspacePath)")

        // "Running" must mean "accepts connections", not merely "process exists".
        Task { @MainActor [weak self] in
            let ready = await Self.waitForSocket(self?.socketPath ?? "")
            guard let self, self.helperProcess === process else { return }
            self.status = ready ? .running : .failed("Helper did not open its socket")
        }
    }

    // MARK: - Exit Handling

    private func helperExited(_ process: Process) {
        let code = process.terminationStatus
        print("[MCPHelperLauncher] ⚠️ Helper exited with code: \(code)")

        // Not the current helper: it was replaced or stopped on purpose.
        guard helperProcess === process else { return }

        detachPipes()
        helperProcess = nil
        // A crashed helper cannot clean up after itself; a stale file would only mislead.
        try? FileManager.default.removeItem(atPath: socketPath)
        guard wantsRunning else { return }

        let uptime = Date().timeIntervalSince(helperStartedAt ?? Date())
        switch restartPolicy.recordExit(uptime: uptime) {
        case .restart(let delay):
            status = .crashed(code: Int(code))
            print("[MCPHelperLauncher] ⏳ Restarting in \(Int(delay)) s")
            pendingRestart = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.wantsRunning, self.helperProcess == nil else { return }
                self.pendingRestart = nil
                self.startHelper()
            }
        case .giveUp:
            status = .failed("Helper keeps crashing (last exit code \(code))")
            print("[MCPHelperLauncher] ❌ Giving up after repeated crashes; a tool call or relaunch will retry")
        }
    }

    // MARK: - Helpers

    private static func logHandler(prefix: String) -> @Sendable (FileHandle) -> Void {
        { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { print("\(prefix) \(trimmed)") }
        }
    }

    /// Polls up to `timeout` seconds until something accepts connections on the socket.
    private static func waitForSocket(_ path: String, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if MCPSocket.canConnect(path) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return MCPSocket.canConnect(path)
    }

    private func jsonString(from map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - HelperStatus

enum HelperStatus: Equatable {
    case notStarted
    case starting
    case running
    case stopped
    case failed(String)
    case crashed(code: Int)

    var description: String {
        switch self {
        case .notStarted:        return "Not started"
        case .starting:          return "Starting"
        case .running:           return "Running"
        case .stopped:           return "Stopped"
        case .failed(let msg):   return "Error: \(msg)"
        case .crashed(let code): return "Crashed (code \(code))"
        }
    }
}
