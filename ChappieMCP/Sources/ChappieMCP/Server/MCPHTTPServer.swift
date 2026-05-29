// MCPHTTPServer.swift
//
// WHY THIS FILE:
// Implements a server based on Unix Domain Socket (UDS).
//
// WHY Unix Domain Socket, NOT TCP:
// ChappieMCP is launched as a child process from Chappie.app, which runs
// in App Sandbox. The child process inherits the parent's sandbox, and the sandbox
// blocks opening server TCP sockets (POSIX error 1: Operation not permitted).
// Unix Domain Socket works through the file system (file in /tmp/),
// the sandbox allows it without additional entitlements.
//
// ADDITIONAL UDS ADVANTAGES:
// - Faster than TCP (no network stack, in-memory copy)
// - More secure (local only, not visible outside the machine)
// - Does not require a free port
//
// SOCKET PATH:
// /tmp/com.chappie.mcp.sock — fixed path known to both server and client.
//
// PROTOCOL (length-prefixed framing):
// Request:  4 bytes (UInt32 big-endian, JSON length) + MCPRequest JSON body
// Response: 4 bytes (UInt32 big-endian, JSON length) + MCPResponse JSON body
// More reliable than HTTP parsing — no issues with headers and chunked encoding.

import Foundation

// MARK: - Constants

/// Path to the Unix Domain Socket file.
/// Why /tmp: standard directory for process temporary files,
/// accessible to all users, requires no special permissions.
let kMCPSocketPath = "/tmp/com.chappie.mcp.sock"

// MARK: - Request/Response Models

/// Request to MCP server.
struct MCPRequest: Codable, Sendable {
    let tool: String
    let args: [String: String]
}

/// MCP server response.
struct MCPResponse: Codable, Sendable {
    let result: String?
    let error: String?
}

// MARK: - MCPUnixServer

/// Server on Unix Domain Socket for MCP tools.
///
/// Why @unchecked Sendable: contains Int32 file descriptor,
/// but we guarantee safety — fd is used only inside acceptLoop
/// on a single DispatchQueue thread.
final class MCPUnixServer: @unchecked Sendable {

    private let socketPath: String
    private let projectPath: String

    /// Tool dispatcher — routes calls to the appropriate classes.
    private let toolDispatcher: ToolDispatcher

    init(socketPath: String = kMCPSocketPath, projectPath: String) {
        self.socketPath = socketPath
        self.projectPath = projectPath
        self.toolDispatcher = ToolDispatcher(projectPath: projectPath)
    }

    /// Starts the POSIX Unix Domain Socket server.
    ///
    /// Removes old socket file (if left from previous run),
    /// creates a new one, starts accepting connections on a background thread.
    func start() throws {
        // Remove old socket file — otherwise bind fails with "Address already in use".
        // This is normal practice for Unix socket servers at startup.
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create Unix Domain Socket
        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw MCPServerError.socketCreationFailed(String(cString: strerror(errno)))
        }

        // Allow address reuse — in case of quick restart
        var reuseAddr: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Form Unix socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path into sun_path (104-byte buffer on macOS)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { charPtr in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(charPtr, src.baseAddress!, min(src.count, 104))
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Bind socket to path in the file system
        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            throw MCPServerError.bindFailed(String(cString: strerror(errno)))
        }

        // Start listening for incoming connections (backlog = 128)
        guard listen(serverFD, 128) == 0 else {
            throw MCPServerError.listenFailed(String(cString: strerror(errno)))
        }

        print("[ChappieMCP] 🟢 Unix socket ready: \(socketPath)")

        // Accept connections on a background thread, not blocking main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.acceptLoop(serverFD: serverFD)
        }
    }

    // MARK: - Accept Loop

    /// Main loop for accepting incoming connections.
    /// Runs indefinitely on a background DispatchQueue thread.
    private func acceptLoop(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            // accept() blocks the thread until a new connection arrives
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientAddrLen)
                }
            }

            guard clientFD >= 0 else {
                print("[ChappieMCP] ⚠️ accept() error: \(String(cString: strerror(errno)))")
                continue
            }

            // Each connection is handled in a separate Swift Concurrency Task,
            // to avoid blocking the accept loop during long operations (xcodebuild).
            Task { [weak self] in
                guard let self else { return }
                await self.handleClient(fd: clientFD)
            }
        }
    }

    // MARK: - Client Handler

    /// Handles a single client connection.
    ///
    /// Protocol (length-prefixed framing):
    /// - Read 4 bytes (UInt32 big-endian) = JSON request length
    /// - Read N bytes of JSON
    /// - Execute the tool
    /// - Send 4 bytes length + JSON response
    private func handleClient(fd: Int32) async {
        defer { close(fd) } // Always close the connection

        // Read 4 bytes of request length
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let bytesRead = recv(fd, &lengthBytes, 4, MSG_WAITALL)
        guard bytesRead == 4 else {
            print("[ChappieMCP] ⚠️ Failed to read message length (read: \(bytesRead))")
            return
        }

        // Decode length (big-endian UInt32)
        let length = UInt32(lengthBytes[0]) << 24
                   | UInt32(lengthBytes[1]) << 16
                   | UInt32(lengthBytes[2]) << 8
                   | UInt32(lengthBytes[3])

        // Guard against too-large or zero requests
        guard length > 0, length < 10_000_000 else {
            print("[ChappieMCP] ⚠️ Invalid message length: \(length)")
            return
        }

        // Read JSON request body
        var jsonBytes = [UInt8](repeating: 0, count: Int(length))
        let jsonRead = recv(fd, &jsonBytes, Int(length), MSG_WAITALL)
        guard jsonRead == Int(length) else {
            print("[ChappieMCP] ⚠️ Incomplete JSON read (expected \(length), got \(jsonRead))")
            return
        }

        // Process request and get response
        let requestData = Data(jsonBytes)
        let responseData = await processRequest(data: requestData)

        // Send response: 4 bytes length (big-endian) + JSON body
        let responseLength = UInt32(responseData.count)
        var responseHeader = [UInt8](repeating: 0, count: 4)
        responseHeader[0] = UInt8((responseLength >> 24) & 0xFF)
        responseHeader[1] = UInt8((responseLength >> 16) & 0xFF)
        responseHeader[2] = UInt8((responseLength >> 8) & 0xFF)
        responseHeader[3] = UInt8(responseLength & 0xFF)

        _ = responseHeader.withUnsafeBytes { send(fd, $0.baseAddress!, 4, 0) }
        _ = responseData.withUnsafeBytes { send(fd, $0.baseAddress!, responseData.count, 0) }
    }

    // MARK: - Request Processing

    /// Decodes JSON request and executes the tool via ToolDispatcher.
    private func processRequest(data: Data) async -> Data {
        guard let request = try? JSONDecoder().decode(MCPRequest.self, from: data) else {
            let response = MCPResponse(result: nil, error: "Invalid JSON request")
            return (try? JSONEncoder().encode(response)) ?? Data()
        }

        print("[ChappieMCP] 🔧 Tool: \(request.tool) | Args: \(request.args)")

        let toolResult = await toolDispatcher.execute(tool: request.tool, args: request.args)
        let response = MCPResponse(result: toolResult.value, error: toolResult.error)
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

// MARK: - MCPServerError

/// Errors when starting Unix Domain Socket server.
enum MCPServerError: Error, CustomStringConvertible {
    case socketCreationFailed(String)
    case bindFailed(String)
    case listenFailed(String)

    var description: String {
        switch self {
        case .socketCreationFailed(let msg): return "Failed to create socket: \(msg)"
        case .bindFailed(let msg):           return "bind() failed: \(msg)"
        case .listenFailed(let msg):         return "listen() failed: \(msg)"
        }
    }
}

// MARK: - ToolResult

/// Tool execution result.
/// Why a separate struct: cleanly separates success and error
/// without throws across async boundaries in the dispatcher.
struct ToolResult: Sendable {
    let value: String?
    let error: String?

    static func success(_ value: String) -> ToolResult {
        ToolResult(value: value, error: nil)
    }

    static func failure(_ error: String) -> ToolResult {
        ToolResult(value: nil, error: error)
    }
}

// MARK: - ToolDispatcher

/// Tool dispatcher — routes calls to the appropriate classes.
///
/// Why a separate class: isolates routing logic from the server.
/// Adding a new tool = one case in the switch.
final class ToolDispatcher: Sendable {
    private let gitTools: GitTools
    private let buildTools: BuildTools

    init(projectPath: String) {
        self.gitTools = GitTools(projectPath: projectPath)
        self.buildTools = BuildTools(projectPath: projectPath)
    }

    func execute(tool: String, args: [String: String]) async -> ToolResult {
        switch tool {

        // Git tools
        case "git_status":
            return await gitTools.status()

        case "git_diff":
            let staged = args["staged"] == "true"
            return await gitTools.diff(staged: staged)

        case "git_add":
            let paths = args["paths"] ?? "."
            return await gitTools.add(paths: paths)

        case "git_commit":
            guard let message = args["message"], !message.isEmpty else {
                return .failure("Argument 'message' is required for git_commit")
            }
            return await gitTools.commit(message: message)

        case "git_log":
            let count = Int(args["count"] ?? "10") ?? 10
            return await gitTools.log(count: count)

        case "git_reset":
            return await gitTools.reset()

        // Rollback tools
        case "git_revert":
            // hashes: space-separated commit hashes to revert, e.g. "abc123 def456"
            // message: commit message for the combined revert commit
            guard let hashes = args["hashes"], !hashes.isEmpty else {
                return .failure("Argument 'hashes' is required for git_revert (space-separated commit hashes)")
            }
            let message = args["message"] ?? "revert: roll back commits \(args["hashes"] ?? "")"
            return await gitTools.revert(hashes: hashes, message: message)

        case "git_checkout":
            // ref: commit hash, branch name, or relative ref like HEAD~1
            // paths: space-separated file paths to restore
            guard let ref = args["ref"], !ref.isEmpty else {
                return .failure("Argument 'ref' is required for git_checkout (e.g. HEAD~1, abc123, main)")
            }
            guard let paths = args["paths"], !paths.isEmpty else {
                return .failure("Argument 'paths' is required for git_checkout (space-separated file paths)")
            }
            return await gitTools.checkout(ref: ref, paths: paths)

        // Build tools
        case "build_project":
            return await buildTools.build()

        case "run_tests":
            let testTarget = args["target"]
            return await buildTools.runTests(target: testTarget)

        case "read_build_log":
            return await buildTools.readLastLog()

        default:
            return .failure(
                "Unknown tool: \(tool). Available: " +
                "git_status, git_diff, git_add, git_commit, git_log, git_reset, " +
                "git_revert, git_checkout, " +
                "build_project, run_tests, read_build_log"
            )
        }
    }
}
