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
let kMCPSocketPath = "/tmp/com.chappie.mcp.sock"

// MARK: - Request/Response Models

struct MCPRequest: Codable, Sendable {
    let tool: String
    let args: [String: String]
}

struct MCPResponse: Codable, Sendable {
    let result: String?
    let error: String?
}

// MARK: - MCPUnixServer

/// Server on Unix Domain Socket for MCP tools.
///
/// Why @unchecked Sendable: contains Int32 file descriptor,
/// but we guarantee safety — fd is used only inside acceptLoop on a single DispatchQueue thread.
final class MCPUnixServer: @unchecked Sendable {

    private let socketPath: String
    private let projectPath: String
    private let toolDispatcher: ToolDispatcher

    init(socketPath: String = kMCPSocketPath, projectPath: String, environment: DevEnvironment = .unknown) {
        self.socketPath = socketPath
        self.projectPath = projectPath
        self.toolDispatcher = ToolDispatcher(projectPath: projectPath, environment: environment)
    }

    func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw MCPServerError.socketCreationFailed(String(cString: strerror(errno)))
        }

        var reuseAddr: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { charPtr in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(charPtr, src.baseAddress!, min(src.count, 104))
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            throw MCPServerError.bindFailed(String(cString: strerror(errno)))
        }

        guard listen(serverFD, 128) == 0 else {
            throw MCPServerError.listenFailed(String(cString: strerror(errno)))
        }

        print("[ChappieMCP] 🟢 Unix socket ready: \(socketPath)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.acceptLoop(serverFD: serverFD)
        }
    }

    // MARK: - Accept Loop

    private func acceptLoop(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientAddrLen)
                }
            }

            guard clientFD >= 0 else {
                print("[ChappieMCP] ⚠️ accept() error: \(String(cString: strerror(errno)))")
                continue
            }

            Task { [weak self] in
                guard let self else { return }
                await self.handleClient(fd: clientFD)
            }
        }
    }

    // MARK: - Client Handler

    private func handleClient(fd: Int32) async {
        defer { close(fd) }

        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let bytesRead = recv(fd, &lengthBytes, 4, MSG_WAITALL)
        guard bytesRead == 4 else {
            print("[ChappieMCP] ⚠️ Failed to read message length (read: \(bytesRead))")
            return
        }

        let length = UInt32(lengthBytes[0]) << 24
                   | UInt32(lengthBytes[1]) << 16
                   | UInt32(lengthBytes[2]) << 8
                   | UInt32(lengthBytes[3])

        guard length > 0, length < 10_000_000 else {
            print("[ChappieMCP] ⚠️ Invalid message length: \(length)")
            return
        }

        var jsonBytes = [UInt8](repeating: 0, count: Int(length))
        let jsonRead = recv(fd, &jsonBytes, Int(length), MSG_WAITALL)
        guard jsonRead == Int(length) else {
            print("[ChappieMCP] ⚠️ Incomplete JSON read (expected \(length), got \(jsonRead))")
            return
        }

        let requestData = Data(jsonBytes)
        let responseData = await processRequest(data: requestData)

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

/// Tool execution result. Separates success/error without throws across async boundaries.
struct ToolResult: Sendable {
    let value: String?
    let error: String?

    static func success(_ value: String) -> ToolResult { ToolResult(value: value, error: nil) }
    static func failure(_ error: String) -> ToolResult { ToolResult(value: nil, error: error) }
}

// MARK: - ToolDispatcher

/// Routes tool calls to the appropriate handler classes.
/// Adding a new tool = one case in the switch.
final class ToolDispatcher: Sendable {
    private let gitTools: GitTools
    private let buildTools: BuildTools
    private let locTools: LocalizationTools

    init(projectPath: String, environment: DevEnvironment) {
        self.gitTools = GitTools(projectPath: projectPath)
        self.buildTools = BuildTools(projectPath: projectPath, environment: environment)
        self.locTools = LocalizationTools(projectPath: projectPath)
    }

    func execute(tool: String, args: [String: String]) async -> ToolResult {
        switch tool {

        // Git tools
        case "git_status":
            return await gitTools.status()

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

        case "git_revert":
            guard let hashes = args["hashes"], !hashes.isEmpty else {
                return .failure("Argument 'hashes' is required (space-separated commit hashes)")
            }
            let message = args["message"] ?? "revert: roll back commits \(args["hashes"] ?? "")"
            return await gitTools.revert(hashes: hashes, message: message)

        case "git_checkout":
            guard let ref = args["ref"], !ref.isEmpty else {
                return .failure("Argument 'ref' is required (e.g. HEAD~1, abc123, main)")
            }
            guard let paths = args["paths"], !paths.isEmpty else {
                return .failure("Argument 'paths' is required (space-separated file paths)")
            }
            return await gitTools.checkout(ref: ref, paths: paths)

        // Build tools
        case "build_project":
            return await buildTools.build()

        case "run_tests":
            return await buildTools.runTests(target: args["target"])

        case "read_build_log":
            return await buildTools.readLastLog()

        // Localization tools (Xcode / xcstrings)
        case "loc_info":
            return locTools.info()

        case "loc_create":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required (e.g. 'Chappie/Localizable.xcstrings')")
            }
            return locTools.create(relativePath: path, sourceLanguage: args["sourceLanguage"] ?? "en")

        case "loc_rename":
            guard let from = args["from"], !from.isEmpty else { return .failure("Argument 'from' is required") }
            guard let to = args["to"], !to.isEmpty else { return .failure("Argument 'to' is required") }
            return locTools.rename(fromRelativePath: from, toRelativePath: to)

        case "loc_delete":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.delete(relativePath: path)

        case "loc_add_language":
            guard let language = args["language"], !language.isEmpty else {
                return .failure("Argument 'language' is required (e.g. 'ru', 'de', 'zh-Hans')")
            }
            return locTools.addLanguage(language: language, relativePath: args["path"])

        case "loc_remove_language":
            guard let language = args["language"], !language.isEmpty else {
                return .failure("Argument 'language' is required")
            }
            return locTools.removeLanguage(language: language, relativePath: args["path"])

        case "loc_key_check":
            guard let key = args["key"], !key.isEmpty else { return .failure("Argument 'key' is required") }
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.keyCheck(key: key, relativePath: path)

        case "loc_next_batch":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.nextBatch(relativePath: path)

        case "loc_submit_batch":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let translations = args["translations"], !translations.isEmpty else {
                return .failure("Argument 'translations' is required (JSON: {\"key\": {\"ru\": \"...\", \"de\": \"...\"}})")
            }
            return locTools.submitBatch(relativePath: path, translationsJSON: translations)

        case "loc_dead_keys":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.deadKeys(relativePath: path)

        case "loc_add_key":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let key = args["key"], !key.isEmpty else { return .failure("Argument 'key' is required") }
            guard let value = args["value"], !value.isEmpty else { return .failure("Argument 'value' is required (English text)") }
            return locTools.addKey(relativePath: path, key: key, englishValue: value, comment: args["comment"])

        case "loc_remove_key":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let key = args["key"], !key.isEmpty else { return .failure("Argument 'key' is required") }
            return locTools.removeKey(relativePath: path, key: key)

        default:
            return .failure("Unknown tool: \(tool).")
        }
    }
}
