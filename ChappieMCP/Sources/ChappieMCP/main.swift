// main.swift — entry point for ChappieMCP
//
// WHY THIS FILE:
// Starts the Unix Domain Socket server and keeps the process alive.
//
// CLI ARGUMENTS:
// argv[0] = binary path (automatic)
// argv[1] = workspace path (working directory for git/build commands)
// argv[2] = Unix Domain Socket file path
// argv[3] = dev environment rawValue (e.g. "xcode", "python", "nodejs") — optional, defaults to "unknown"
//
// WHY PASS SOCKET PATH VIA ARGUMENT:
// Parent (Chappie.app) is the single source of truth about the socket path.
// Helper should not independently decide on file paths.
//
// WHY PASS DEV ENVIRONMENT VIA ARGUMENT:
// MCP helper is a standalone binary — it cannot import ChappieCore.
// Parent knows the active project's devEnvironment and passes it as a string rawValue.
// This makes build_project and run_tests deterministic per environment.
//
// MANUAL LAUNCH (for debugging):
//   .build/debug/ChappieMCP /path/to/project /tmp/com.chappie.mcp.sock xcode

import Foundation

let args = CommandLine.arguments

let projectPath: String = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
let socketPath: String  = args.count > 2 ? args[2] : "/tmp/com.chappie.mcp.sock"
let environment: DevEnvironment = args.count > 3 ? (DevEnvironment(rawValue: args[3]) ?? .unknown) : .unknown

print("[ChappieMCP] 🚀 Starting server (Unix Domain Socket)")
print("[ChappieMCP] 📁 Workspace: \(projectPath)")
print("[ChappieMCP] 🔌 Socket:    \(socketPath)")
print("[ChappieMCP] 🛠️  Env:       \(environment.rawValue)")

let server = MCPUnixServer(socketPath: socketPath, projectPath: projectPath, environment: environment)

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
