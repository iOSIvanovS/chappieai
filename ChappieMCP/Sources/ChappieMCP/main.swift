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
//   .build/debug/ChappieMCP /path/to/workspace /tmp/com.chappie.mcp.sock \
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
let socketPath: String  = args.count > 2 ? args[2] : "/tmp/com.chappie.mcp.sock"

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

do {
    try server.start()
    print("[ChappieMCP] ✅ Server started. Waiting for requests...")
} catch {
    print("[ChappieMCP] ❌ Failed to start server: \(error)")
    exit(1)
}

// Keep process alive — server runs on a background DispatchQueue.
RunLoop.main.run()
