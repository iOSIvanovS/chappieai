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
// MISBEHAVING CLIENTS:
// Socket reads/writes block, so they run on a dedicated concurrent DispatchQueue and never on
// Swift concurrency's cooperative pool (a handful of silent clients used to pin every pool
// thread and starve real tool calls). Every transfer has a deadline, and the number of
// connections still sending their request is capped.
//
// MULTI-PROJECT ROUTING:
// ToolDispatcher holds:
//   - projectEnvMap  [projectName → devEnvironment rawValue] — for build/test env routing
//   - projectPathMap [projectName → absolutePath]            — for git AND build path routing
// Both maps are populated from CLI argv[3] and argv[4] respectively.
// git_* tools use projectPathMap to resolve working directory per project.
// build_project/run_tests use BOTH maps: projectEnvMap for env, projectPathMap for path.

import Foundation

// MARK: - MCPUnixServer

final class MCPUnixServer: @unchecked Sendable {

    /// The app sends its request right after connecting, so this is generous. It bounds only
    /// reading the request, never running the tool (a build may legitimately take minutes).
    static let requestReadTimeout: TimeInterval = 10
    static let responseWriteTimeout: TimeInterval = 10
    /// Connections that are still delivering their request. Extra ones are dropped immediately.
    static let maxPendingConnections = 32
    private static let maxMessageLength: UInt32 = 10_000_000

    private let socketPath: String
    private let projectPath: String
    private let toolDispatcher: ToolDispatcher

    private let ioQueue = DispatchQueue(label: "com.chappie.mcp.socket-io",
                                        qos: .userInitiated,
                                        attributes: .concurrent)
    private let pendingLock = NSLock()
    private var pendingConnections = 0
    private var boundInode: ino_t = 0

    init(socketPath: String,
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

        var created = stat()
        if stat(socketPath, &created) == 0 { boundInode = created.st_ino }

        print("[ChappieMCP] 🟢 Unix socket ready: \(socketPath)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.acceptLoop(serverFD: serverFD)
        }
    }

    // MARK: - Accept Loop

    private func acceptLoop(serverFD: Int32) {
        var inResourceStarvation = false

        while true {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientAddrLen)
                }
            }

            guard clientFD >= 0 else {
                let code = errno
                switch Self.classifyAcceptError(code) {
                case .retryNow:
                    continue
                case .backOff:
                    // Out of descriptors/memory: spinning would burn CPU and flood the log.
                    if !inResourceStarvation {
                        print("[ChappieMCP] ⚠️ accept() resource shortage: \(String(cString: strerror(code))); backing off")
                        inResourceStarvation = true
                    }
                    usleep(100_000)
                    continue
                case .fatal:
                    // Accepting is gone for good; exit so the app's launcher starts a fresh helper
                    // instead of leaving a process that listens to nobody.
                    print("[ChappieMCP] ❌ accept() fatal: \(String(cString: strerror(code))); exiting")
                    removeOwnSocket()
                    exit(1)
                }
            }
            inResourceStarvation = false

            guard reservePendingSlot() else {
                print("[ChappieMCP] ⚠️ Too many pending connections (\(Self.maxPendingConnections)); dropping one")
                close(clientFD)
                continue
            }

            ioQueue.async { [weak self] in
                guard let self else { close(clientFD); return }
                self.serve(fd: clientFD)
            }
        }
    }

    enum AcceptErrorAction: Equatable {
        case retryNow, backOff, fatal
    }

    static func classifyAcceptError(_ code: Int32) -> AcceptErrorAction {
        switch code {
        case EINTR, ECONNABORTED, EAGAIN, EPROTO:
            return .retryNow
        case EMFILE, ENFILE, ENOMEM, ENOBUFS:
            return .backOff
        default:
            return .fatal
        }
    }

    private func removeOwnSocket() {
        var current = stat()
        if boundInode != 0, stat(socketPath, &current) == 0, current.st_ino == boundInode {
            unlink(socketPath)
        }
    }

    // MARK: - Pending-connection accounting

    private func reservePendingSlot() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard pendingConnections < Self.maxPendingConnections else { return false }
        pendingConnections += 1
        return true
    }

    private func releasePendingSlot() {
        pendingLock.lock()
        pendingConnections -= 1
        pendingLock.unlock()
    }

    // MARK: - Client Handler

    /// Reads one request (blocking, bounded), then hands the tool run to Swift concurrency.
    /// Runs on `ioQueue`. Owns `fd` and closes it on every path.
    private func serve(fd: Int32) {
        // Belt and braces next to the process-wide SIGPIPE ignore: a write to a vanished
        // client must fail with EPIPE instead of signalling.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let deadline = Date().addingTimeInterval(Self.requestReadTimeout)

        guard let requestData = readRequest(fd: fd, deadline: deadline) else {
            releasePendingSlot()
            close(fd)
            return
        }
        releasePendingSlot()

        Task { [weak self] in
            guard let self else { close(fd); return }
            let responseData = await self.processRequest(data: requestData)
            self.ioQueue.async { [weak self] in
                self?.writeResponse(fd: fd, data: responseData)
                close(fd)
            }
        }
    }

    private func readRequest(fd: Int32, deadline: Date) -> Data? {
        switch SocketIO.readExactly(fd: fd, count: 4, deadline: deadline) {
        case .data(let header):
            let length = UInt32(header[0]) << 24
                       | UInt32(header[1]) << 16
                       | UInt32(header[2]) << 8
                       | UInt32(header[3])
            guard length > 0, length < Self.maxMessageLength else {
                print("[ChappieMCP] ⚠️ Invalid message length: \(length)")
                return nil
            }
            switch SocketIO.readExactly(fd: fd, count: Int(length), deadline: deadline) {
            case .data(let body):
                return Data(body)
            case .closed(let received):
                print("[ChappieMCP] ⚠️ Incomplete JSON read (expected \(length), got \(received))")
            case .timedOut:
                print("[ChappieMCP] ⚠️ Timed out reading request body; closing connection")
            case .failed(let reason):
                print("[ChappieMCP] ⚠️ Failed to read request body: \(reason)")
            }
            return nil
        case .closed(let received):
            // 0 = the peer connected and left at once: the app's readiness probe, not an error.
            if received != 0 {
                print("[ChappieMCP] ⚠️ Failed to read message length (read: \(received))")
            }
            return nil
        case .timedOut:
            print("[ChappieMCP] ⚠️ Timed out waiting for a request; closing silent connection")
            return nil
        case .failed(let reason):
            print("[ChappieMCP] ⚠️ Failed to read message length: \(reason)")
            return nil
        }
    }

    private func writeResponse(fd: Int32, data: Data) {
        let length = UInt32(data.count)
        var framed = Data([
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
        framed.append(data)

        let deadline = Date().addingTimeInterval(Self.responseWriteTimeout)
        switch SocketIO.writeAll(fd: fd, data: framed, deadline: deadline) {
        case .done:
            break
        case .timedOut:
            print("[ChappieMCP] ⚠️ Client did not read the response in time; closing connection")
        case .failed(let reason):
            // EPIPE etc.: the client left (cancelled call); nothing to do.
            print("[ChappieMCP] ℹ️ Response not delivered: \(reason)")
        }
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
