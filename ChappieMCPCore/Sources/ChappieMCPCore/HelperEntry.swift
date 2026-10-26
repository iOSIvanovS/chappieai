// HelperEntry.swift
// ChappieMCPCore
//
// Everything the ChappieMCP executable does at startup. main.swift is a one-line call into
// `ChappieMCPHelper.run`, so the only public surface of this library is this entry point and the
// pure argument parser below; the rest stays internal and is reached by tests via @testable.
//
// CLI ARGUMENTS:
// argv[1] = workspace path (may be "" or "/" meaning "none")
// argv[2] = Unix Domain Socket path (required; owned by the launching app instance)
// argv[3] = JSON map projectName → devEnvironment rawValue, e.g. {"Chappie":"xcode"}
// argv[4] = JSON map projectName → absolute path on disk (defaults to "{}")

import Foundation
import Darwin

// MARK: - Arguments

/// Parsed command line of the helper.
struct HelperArguments: Equatable {
    var projectPath: String
    var socketPath: String
    var projectEnvMap: [String: String]
    var projectPathMap: [String: String]

    /// nil when the mandatory socket path is missing.
    static func parse(_ args: [String]) -> HelperArguments? {
        // "/" and "" mean "no workspace folder chosen" (the app used to pass the launch
        // directory, which is "/" under Xcode). Such a root would make every path "inside the
        // project", so it is dropped; the per-project roots from argv[4] are the real boundaries.
        let projectPath = (args.count > 1 && PathGuard.isUsableRoot(args[1])) ? args[1] : ""

        // No default socket path: a fixed fallback is what let two app instances trample each other.
        guard args.count > 2, !args[2].isEmpty else { return nil }

        return HelperArguments(
            projectPath: projectPath,
            socketPath: args[2],
            projectEnvMap: decodeMap(args, at: 3),
            projectPathMap: decodeMap(args, at: 4)
        )
    }

    private static func decodeMap(_ args: [String], at index: Int) -> [String: String] {
        guard args.count > index,
              let data = args[index].data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }
}

// MARK: - Entry point

public enum ChappieMCPHelper {

    /// Starts the server and never returns (runs the main run loop).
    public static func run(arguments: [String]) -> Never {
        // A client may disconnect while a long tool (build, tests) is still running; writing the
        // response to the closed socket then raises SIGPIPE, whose default action kills the whole
        // helper and leaves a stale socket file behind ("Connection refused" for every later call).
        signal(SIGPIPE, SIG_IGN)

        guard let parsed = HelperArguments.parse(arguments) else {
            print("[ChappieMCP] ❌ Usage: ChappieMCP <workspace> <socketPath> [envMapJSON] [pathMapJSON]")
            exit(2)
        }

        print("[ChappieMCP] 🚀 Starting server (Unix Domain Socket)")
        print("[ChappieMCP] 📁 Workspace: \(parsed.projectPath.isEmpty ? "(none)" : parsed.projectPath)")
        print("[ChappieMCP] 🔌 Socket:    \(parsed.socketPath)")
        print("[ChappieMCP] 🗺️  Envs:     \(parsed.projectEnvMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        print("[ChappieMCP] 📂 Paths:    \(parsed.projectPathMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")

        let server = MCPUnixServer(
            socketPath: parsed.socketPath,
            projectPath: parsed.projectPath,
            projectEnvMap: parsed.projectEnvMap,
            projectPathMap: parsed.projectPathMap
        )

        let socketPath = parsed.socketPath
        let boundInode: ino_t
        do {
            try server.start()
            var created = stat()
            boundInode = stat(socketPath, &created) == 0 ? created.st_ino : 0
            print("[ChappieMCP] ✅ Server started. Waiting for requests...")
        } catch {
            print("[ChappieMCP] ❌ Failed to start server: \(error)")
            exit(1)
        }

        /// Removes our socket file and exits. Without this a dead helper leaves a socket that
        /// accepts no connections ("Connection refused" for every later call).
        func shutdown(_ reason: String) -> Never {
            print("[ChappieMCP] 🛑 Exiting: \(reason)")
            // On a restart the launcher starts the new helper on the same path while this one is
            // still being stopped. Unlink only the file we created, or we would delete the new
            // helper's socket.
            var current = stat()
            if boundInode != 0, stat(socketPath, &current) == 0, current.st_ino == boundInode {
                unlink(socketPath)
            }
            exit(0)
        }

        // SIGTERM is how the launcher stops us; default handling would skip the cleanup above.
        signal(SIGTERM, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { shutdown("SIGTERM") }
        termSource.resume()

        // The app can vanish without running any cleanup (Xcode "Stop" is SIGKILL), and nothing
        // tells a child its parent is gone except being re-parented to launchd. Poll that once a
        // second: cheap and much simpler than kqueue process monitoring.
        let originalParent = getppid()
        let parentWatch = DispatchSource.makeTimerSource(queue: .main)
        parentWatch.schedule(deadline: .now() + 1, repeating: 1)
        parentWatch.setEventHandler {
            if getppid() != originalParent { shutdown("parent process \(originalParent) is gone") }
        }
        parentWatch.resume()

        // Keep the process alive; the server runs on background dispatch queues.
        withExtendedLifetime((server, termSource, parentWatch)) {
            RunLoop.main.run()
        }
        exit(0)
    }
}
