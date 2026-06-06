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
//           Defaults to "{}" if omitted.
//
// WHY JSON MAP INSTEAD OF SINGLE ENV:
// Multiple projects with different environments can be attached to the same thread.
// build_project/run_tests carry a "project" arg — MCP resolves the env from the map.
// This guarantees deterministic tool behavior per project regardless of thread composition.
//
// MANUAL LAUNCH (for debugging):
//   .build/debug/ChappieMCP /path/to/project /tmp/com.chappie.mcp.sock '{"MyApp":"xcode"}'

import Foundation

let args = CommandLine.arguments

let projectPath: String = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
let socketPath: String  = args.count > 2 ? args[2] : "/tmp/com.chappie.mcp.sock"

// Parse JSON map: {"ProjectName": "envRawValue", ...}
let projectEnvMap: [String: String] = {
    guard args.count > 3,
          let data = args[3].data(using: .utf8),
          let map = try? JSONDecoder().decode([String: String].self, from: data) else {
        return [:]
    }
    return map
}()

print("[ChappieMCP] 🚀 Starting server (Unix Domain Socket)")
print("[ChappieMCP] 📁 Workspace: \(projectPath)")
print("[ChappieMCP] 🔌 Socket:    \(socketPath)")
print("[ChappieMCP] 🗺️  Projects:  \(projectEnvMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")

let server = MCPUnixServer(socketPath: socketPath, projectPath: projectPath, projectEnvMap: projectEnvMap)

do {
    try server.start()
    print("[ChappieMCP] ✅ Server started. Waiting for requests...")
} catch {
    print("[ChappieMCP] ❌ Failed to start server: \(error)")
    exit(1)
}

// Keep process alive — server runs on a background DispatchQueue.
// RunLoop.main.run() blocks the main thread until SIGTERM from MCPHelperLauncher.terminateHelper().
RunLoop.main.run()
