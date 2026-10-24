// main.swift — entry point for ChappieMCP
//
// WHY THIS FILE:
// Starts the Unix Domain Socket server and keeps the process alive.
//
// CLI ARGUMENTS:
// argv[0] = binary path (automatic)
// argv[1] = workspace path (working directory for git/build commands)
// argv[2] = Unix Domain Socket file path
// argv[3] = JSON map of projectName → devEnvironment rawValue
//           e.g. {"Chappie":"xcode","PythonBot":"python"}
//           Used by build_project/run_tests to route to the correct env.
// argv[4] = JSON map of projectName → absolutePath on disk
//           e.g. {"Chappie":"/Volumes/Work/Chappie","Backend":"/Volumes/Work/Backend"}
//           Used by git_* tools to run in the correct project directory.
//           Defaults to "{}" if omitted.
//
// MANUAL LAUNCH (for debugging):
//   .build/debug/ChappieMCP /path/to/workspace /tmp/com.chappie.mcp.test.sock \
//     '{"Chappie":"xcode"}' '{"Chappie":"/path/to/Chappie"}'

import Foundation

// A client may disconnect while a long tool (build, tests) is still running; writing the
// response to the closed socket then raises SIGPIPE, whose default action kills the whole
// helper and leaves a stale socket file behind ("Connection refused" for every later call).
signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments

// "/" and "" mean "no workspace folder chosen" (the app used to pass the launch directory,
// which is "/" under Xcode). Such a root would make every path "inside the project", so it is
// dropped; the per-project roots from argv[4] are the real boundaries.
let projectPath: String = {
    guard args.count > 1, PathGuard.isUsableRoot(args[1]) else { return "" }
    return args[1]
}()

// The socket path is owned by the launching app instance (it contains the app's PID), so there
// is deliberately no default: a fixed fallback is what let two instances trample each other.
guard args.count > 2, !args[2].isEmpty else {
    print("[ChappieMCP] ❌ Usage: ChappieMCP <workspace> <socketPath> [envMapJSON] [pathMapJSON]")
    exit(2)
}
let socketPath: String = args[2]

// Parse argv[3]: {"ProjectName": "envRawValue", ...}
let projectEnvMap: [String: String] = {
    guard args.count > 3,
          let data = args[3].data(using: .utf8),
          let map = try? JSONDecoder().decode([String: String].self, from: data) else {
        return [:]
    }
    return map
}()

// Parse argv[4]: {"ProjectName": "/absolute/path", ...}
// Used by git_* tools to resolve the correct working directory per project.
let projectPathMap: [String: String] = {
    guard args.count > 4,
          let data = args[4].data(using: .utf8),
          let map = try? JSONDecoder().decode([String: String].self, from: data) else {
        return [:]
    }
    return map
}()

print("[ChappieMCP] 🚀 Starting server (Unix Domain Socket)")
print("[ChappieMCP] 📁 Workspace: \(projectPath.isEmpty ? "(none)" : projectPath)")
print("[ChappieMCP] 🔌 Socket:    \(socketPath)")
print("[ChappieMCP] 🗺️  Envs:     \(projectEnvMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
print("[ChappieMCP] 📂 Paths:    \(projectPathMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")

let server = MCPUnixServer(
    socketPath: socketPath,
    projectPath: projectPath,
    projectEnvMap: projectEnvMap,
    projectPathMap: projectPathMap
)

// Identity of the socket file we bound (see shutdown()). Written once before any handler
// that reads it is installed, so unsynchronised access is safe.
nonisolated(unsafe) var boundInode: ino_t = 0

do {
    try server.start()
    var created = stat()
    if stat(socketPath, &created) == 0 { boundInode = created.st_ino }
    print("[ChappieMCP] ✅ Server started. Waiting for requests...")
} catch {
    print("[ChappieMCP] ❌ Failed to start server: \(error)")
    exit(1)
}

// MARK: - Shutdown handling

/// Removes our socket file and exits. Without this a dead helper leaves a socket that accepts
/// no connections ("Connection refused" for every later call).
func shutdown(_ reason: String) -> Never {
    print("[ChappieMCP] 🛑 Exiting: \(reason)")
    // On a restart the launcher starts the new helper on the same path while this one is still
    // being stopped. Unlink only the file we created, or we would delete the new helper's socket.
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

// The app can vanish without running any cleanup (Xcode "Stop" is SIGKILL), and nothing tells
// a child its parent is gone except being re-parented to launchd. Poll that once a second —
// cheap and much simpler than kqueue process monitoring.
let originalParent = getppid()
let parentWatch = DispatchSource.makeTimerSource(queue: .main)
parentWatch.schedule(deadline: .now() + 1, repeating: 1)
parentWatch.setEventHandler {
    if getppid() != originalParent { shutdown("parent process \(originalParent) is gone") }
}
parentWatch.resume()

// Keep process alive — server runs on a background DispatchQueue.
RunLoop.main.run()
