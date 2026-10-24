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
// The default path is per app process (MCPSocket), so two Chappie instances never share a helper.

import Foundation

// MARK: - MCPToolBridge

/// Client for ChappieMCP server over Unix Domain Socket.
/// Actor isolation ensures safe async access to POSIX socket operations.
public actor MCPToolBridge {

    private let socketPath: String
    /// Build tasks can take minutes — large timeout is intentional.
    private let timeoutSeconds: Double

    /// Asked to bring the helper back when a call finds nobody listening. The app's launcher
    /// owns the process, so the bridge only knows "please recover", not how.
    private var recoveryHandler: (@Sendable () async -> Void)?

    public init(
        socketPath: String = MCPSocket.currentProcessPath,
        timeoutSeconds: Double = 600
    ) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func setRecoveryHandler(_ handler: (@Sendable () async -> Void)?) {
        recoveryHandler = handler
    }

    // MARK: - Public API

    public func execute(tool: String, args: [String: String] = [:]) async -> String {
        let first = await sendRequest(tool: tool, args: args)
        guard case .unreachable(let reason) = first else { return first.text }
        if Task.isCancelled { return Self.cancelledMessage(tool) }

        // Nobody is listening (helper died, never started, or its socket file is stale).
        // Safe to retry: the request never reached a helper, so the tool did not run.
        guard let recoveryHandler else { return Self.unavailableMessage(reason, socketPath) }
        await recoveryHandler()
        let second = await sendRequest(tool: tool, args: args)
        if case .unreachable(let reason) = second { return Self.unavailableMessage(reason, socketPath) }
        return second.text
    }

    static func cancelledMessage(_ tool: String) -> String {
        "🛑 Tool \(tool) was cancelled by the user. Its processes are being stopped."
    }

    private static func unavailableMessage(_ reason: String, _ path: String) -> String {
        """
        ❌ ChappieMCP server unavailable (\(reason); socket: \(path)).

        The helper starts automatically with Chappie and is restarted after a crash. \
        If this persists, restart the app.
        """
    }

    // MARK: - Private

    private enum Outcome {
        /// Connection could not be established — the request was never delivered.
        case unreachable(String)
        /// A request was delivered (the answer may still be an error text).
        case answered(String)

        var text: String {
            switch self {
            case .unreachable(let reason): return reason
            case .answered(let text): return text
            }
        }
    }

    /// Wraps blocking POSIX recv() in a continuation to avoid blocking the Swift Concurrency pool.
    private func sendRequest(tool: String, args: [String: String]) async -> Outcome {
        let request = MCPRequestBody(tool: tool, args: args)
        guard let requestData = try? JSONEncoder().encode(request) else {
            return .answered("❌ Error: failed to serialize request for tool \(tool)")
        }

        // Stop must not wait for the helper: cancelling half-closes the socket, which wakes the
        // blocked recv() at once. The helper notices the hang-up and kills the tool's processes.
        let call = CancellableCall()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [socketPath, timeoutSeconds] in
                    let result = Self.performSocketCall(
                        socketPath: socketPath,
                        requestData: requestData,
                        tool: tool,
                        timeoutSeconds: timeoutSeconds,
                        call: call
                    )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            call.cancel()
        }
    }

    /// Synchronous POSIX socket call — runs on a background thread.
    /// Static because actor isolation prevents access to self from a DispatchQueue closure.
    private static func performSocketCall(
        socketPath: String,
        requestData: Data,
        tool: String,
        timeoutSeconds: Double,
        call: CancellableCall
    ) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .answered("❌ Failed to create socket: \(String(cString: strerror(errno)))")
        }
        // Detach before closing so a late cancel can never touch a reused descriptor.
        defer { call.detach(); close(fd) }
        call.attach(fd: fd)
        if call.isCancelled { return .answered(cancelledMessage(tool)) }

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
            // ENOENT / ECONNREFUSED: no helper behind the socket — recoverable by a restart.
            let code = errno
            let reason = "connect failed: \(String(cString: strerror(code)))"
            if code == ENOENT || code == ECONNREFUSED { return .unreachable(reason) }
            return .answered("❌ Failed to connect to ChappieMCP (\(socketPath)): \(String(cString: strerror(code)))")
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
            return .answered("❌ Header send error: \(String(cString: strerror(errno)))")
        }

        let bodySent = requestData.withUnsafeBytes { send(fd, $0.baseAddress!, requestData.count, 0) }
        guard bodySent == requestData.count else {
            return .answered("❌ Request body send error: \(String(cString: strerror(errno)))")
        }

        // Read response: 4-byte length header first
        var responseHeader = [UInt8](repeating: 0, count: 4)
        let headerRead = recv(fd, &responseHeader, 4, MSG_WAITALL)
        guard headerRead == 4 else {
            if call.isCancelled { return .answered(cancelledMessage(tool)) }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return .answered("⏱️ Timeout: tool \(tool) took too long (>\(Int(timeoutSeconds)) sec)")
            }
            return .answered("❌ Response header read error: \(String(cString: strerror(errno)))")
        }

        let responseLength = UInt32(responseHeader[0]) << 24
                           | UInt32(responseHeader[1]) << 16
                           | UInt32(responseHeader[2]) << 8
                           | UInt32(responseHeader[3])

        guard responseLength > 0, responseLength < 10_000_000 else {
            return .answered("❌ Invalid response length from server: \(responseLength)")
        }

        var responseBytes = [UInt8](repeating: 0, count: Int(responseLength))
        let bodyRead = recv(fd, &responseBytes, Int(responseLength), MSG_WAITALL)
        guard bodyRead == Int(responseLength) else {
            if call.isCancelled { return .answered(cancelledMessage(tool)) }
            return .answered("❌ Incomplete response from server (expected \(responseLength), got \(bodyRead))")
        }

        let responseData = Data(responseBytes)
        guard let response = try? JSONDecoder().decode(MCPResponseBody.self, from: responseData) else {
            let raw = String(data: responseData, encoding: .utf8) ?? "unreadable response"
            return .answered("❌ Failed to decode MCP server response: \(raw)")
        }

        if let error = response.error {
            return .answered("❌ Tool \(tool) error: \(error)")
        }
        return .answered(response.result ?? "(empty result)")
    }
}

// MARK: - CancellableCall

/// Lets the task's cancellation handler reach the blocking socket call running on a GCD thread.
final class CancellableCall: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func attach(fd: Int32) { lock.withLock { self.fd = fd } }
    func detach() { lock.withLock { fd = -1 } }

    /// A half-close keeps the descriptor valid for its owner while waking its blocked recv().
    func cancel() {
        lock.withLock {
            cancelled = true
            if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        }
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
