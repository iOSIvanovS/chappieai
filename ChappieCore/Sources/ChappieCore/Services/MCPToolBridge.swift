// MCPToolBridge.swift
// ChappieCore
//
// Why Unix Domain Socket: App Sandbox blocks TCP server in child processes,
// but allows UDS bind inside the sandbox temp directory.
//
// Why sandbox temp dir: FileManager.default.temporaryDirectory returns a path
// inside the sandbox container (/var/folders/.../T/) where bind() is allowed.
// The path is computed by MCPHelperLauncher and passed via ToolExecutionService.init(socketPath:).
//
// Protocol: length-prefixed framing — 4 bytes (UInt32 big-endian) + JSON body.
//
// Why no kSocketPath constant: ChappieCore is a public Swift Package. Default
// arguments in public inits must be accessible to callers, so the path lives
// directly in the default argument — idiomatic Swift.

import Foundation

// MARK: - MCPToolBridge

/// Client for ChappieMCP server over Unix Domain Socket.
/// Actor isolation ensures safe async access to POSIX socket operations.
public actor MCPToolBridge {

    private let socketPath: String
    /// Build tasks can take minutes — large timeout is intentional.
    private let timeoutSeconds: Double

    public init(
        socketPath: String = "/tmp/com.chappie.mcp.sock",
        timeoutSeconds: Double = 600
    ) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Public API

    public func execute(tool: String, args: [String: String] = [:]) async -> String {
        // Socket file absence means the MCP server is not running.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return """
            ❌ ChappieMCP server unavailable (socket not found: \(socketPath)).
            
            The helper should start automatically when Chappie.app launches.
            If it didn't — restart the app.
            """
        }
        return await sendRequest(tool: tool, args: args)
    }

    // MARK: - Private

    /// Wraps blocking POSIX recv() in a continuation to avoid blocking the Swift Concurrency pool.
    private func sendRequest(tool: String, args: [String: String]) async -> String {
        let request = MCPRequestBody(tool: tool, args: args)
        guard let requestData = try? JSONEncoder().encode(request) else {
            return "❌ Error: failed to serialize request for tool \(tool)"
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [socketPath, timeoutSeconds] in
                let result = Self.performSocketCall(
                    socketPath: socketPath,
                    requestData: requestData,
                    tool: tool,
                    timeoutSeconds: timeoutSeconds
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronous POSIX socket call — runs on a background thread.
    /// Static because actor isolation prevents access to self from a DispatchQueue closure.
    private static func performSocketCall(
        socketPath: String,
        requestData: Data,
        tool: String,
        timeoutSeconds: Double
    ) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return "❌ Failed to create socket: \(String(cString: strerror(errno)))"
        }
        defer { close(fd) }

        var timeout = timeval(
            tv_sec: __darwin_time_t(Int(timeoutSeconds)),
            tv_usec: 0
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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

        let connectResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            return "❌ Failed to connect to ChappieMCP (\(socketPath)): \(String(cString: strerror(errno)))"
        }

        // Send: 4-byte big-endian length header + JSON body
        let length = UInt32(requestData.count)
        var header = [UInt8](repeating: 0, count: 4)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        let headerSent = header.withUnsafeBytes { send(fd, $0.baseAddress!, 4, 0) }
        guard headerSent == 4 else {
            return "❌ Header send error: \(String(cString: strerror(errno)))"
        }

        let bodySent = requestData.withUnsafeBytes { send(fd, $0.baseAddress!, requestData.count, 0) }
        guard bodySent == requestData.count else {
            return "❌ Request body send error: \(String(cString: strerror(errno)))"
        }

        // Read response: 4-byte length header first
        var responseHeader = [UInt8](repeating: 0, count: 4)
        let headerRead = recv(fd, &responseHeader, 4, MSG_WAITALL)
        guard headerRead == 4 else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return "⏱️ Timeout: tool \(tool) took too long (>\(Int(timeoutSeconds)) sec)"
            }
            return "❌ Response header read error: \(String(cString: strerror(errno)))"
        }

        let responseLength = UInt32(responseHeader[0]) << 24
                           | UInt32(responseHeader[1]) << 16
                           | UInt32(responseHeader[2]) << 8
                           | UInt32(responseHeader[3])

        guard responseLength > 0, responseLength < 10_000_000 else {
            return "❌ Invalid response length from server: \(responseLength)"
        }

        var responseBytes = [UInt8](repeating: 0, count: Int(responseLength))
        let bodyRead = recv(fd, &responseBytes, Int(responseLength), MSG_WAITALL)
        guard bodyRead == Int(responseLength) else {
            return "❌ Incomplete response from server (expected \(responseLength), got \(bodyRead))"
        }

        let responseData = Data(responseBytes)
        guard let response = try? JSONDecoder().decode(MCPResponseBody.self, from: responseData) else {
            let raw = String(data: responseData, encoding: .utf8) ?? "unreadable response"
            return "❌ Failed to decode MCP server response: \(raw)"
        }

        if let error = response.error {
            return "❌ Tool \(tool) error: \(error)"
        }
        return response.result ?? "(empty result)"
    }
}

// MARK: - Request / Response models

private struct MCPRequestBody: Codable, Sendable {
    let tool: String
    let args: [String: String]
}

private struct MCPResponseBody: Codable, Sendable {
    let result: String?
    let error: String?
}
