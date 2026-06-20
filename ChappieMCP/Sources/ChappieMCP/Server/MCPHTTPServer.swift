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
// PROTOCOL (length-prefixed framing):
// Request:  4 bytes (UInt32 big-endian, JSON length) + MCPRequest JSON body
// Response: 4 bytes (UInt32 big-endian, JSON length) + MCPResponse JSON body
//
// MULTI-PROJECT ROUTING:
// ToolDispatcher holds:
//   - projectEnvMap  [projectName → devEnvironment rawValue] — for build/test env routing
//   - projectPathMap [projectName → absolutePath]            — for git AND build path routing
// Both maps are populated from CLI argv[3] and argv[4] respectively.
// git_* tools use projectPathMap to resolve working directory per project.
// build_project/run_tests use BOTH maps: projectEnvMap for env, projectPathMap for path.

import Foundation

// MARK: - Constants

let kMCPSocketPath = "/tmp/com.chappie.mcp.sock"

// MARK: - MCPUnixServer

final class MCPUnixServer: @unchecked Sendable {

    private let socketPath: String
    private let projectPath: String
    private let toolDispatcher: ToolDispatcher

    init(socketPath: String = kMCPSocketPath,
         projectPath: String,
         projectEnvMap: [String: String] = [:],
         projectPathMap: [String: String] = [:]) {
        self.socketPath = socketPath
        self.projectPath = projectPath
        self.toolDispatcher = ToolDispatcher(
            projectPath: projectPath,
            projectEnvMap: projectEnvMap,
            projectPathMap: projectPathMap
        )
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
