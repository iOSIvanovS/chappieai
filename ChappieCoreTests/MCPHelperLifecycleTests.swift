// MCPHelperLifecycleTests.swift
// ChappieCoreTests
//
// Covers the pure parts of the helper lifecycle: per-instance socket naming, stale-socket
// detection, restart back-off, and the bridge's "recover and retry once" behaviour.
// Real process handling (kill helper, kill parent) is verified live, not here.

import Testing
import Foundation
@testable import ChappieCore

@Suite("MCP socket naming and stale detection")
struct MCPSocketTests {

    @Test func pathContainsPID() {
        #expect(MCPSocket.path(forPID: 4242) == "/tmp/com.chappie.mcp.4242.sock")
    }

    @Test func currentProcessPathUsesOwnPID() {
        #expect(MCPSocket.currentProcessPath == MCPSocket.path(forPID: getpid()))
    }

    @Test func parsesOwnerPID() {
        #expect(MCPSocket.pid(fromFileName: "com.chappie.mcp.123.sock") == 123)
    }

    @Test func rejectsForeignAndLegacyNames() {
        #expect(MCPSocket.pid(fromFileName: "com.chappie.mcp.sock") == nil)       // legacy fixed name
        #expect(MCPSocket.pid(fromFileName: "com.chappie.mcp..sock") == nil)
        #expect(MCPSocket.pid(fromFileName: "com.chappie.mcp.abc.sock") == nil)
        #expect(MCPSocket.pid(fromFileName: "com.chappie.mcp.12a.sock") == nil)
        #expect(MCPSocket.pid(fromFileName: "other.123.sock") == nil)
        #expect(MCPSocket.pid(fromFileName: "com.chappie.mcp.99") == nil)
    }

    @Test func staleDetectionKeepsLiveOwnAndUnrelated() {
        let names = [
            "com.chappie.mcp.100.sock",   // dead
            "com.chappie.mcp.200.sock",   // alive
            "com.chappie.mcp.300.sock",   // own
            "com.chappie.mcp.sock",       // legacy — never touched
            "unrelated.txt"
        ]
        let stale = MCPSocket.staleSocketNames(among: names, ownPID: 300) { $0 == 200 || $0 == 300 }
        #expect(stale == ["com.chappie.mcp.100.sock"])
    }

    @Test func removeStaleSocketsDeletesOnlyDeadOwners() throws {
        let dir = NSTemporaryDirectory() + "mcpsock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in ["com.chappie.mcp.111.sock", "com.chappie.mcp.222.sock", "com.chappie.mcp.sock", "note.txt"] {
            FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data())
        }

        let removed = MCPSocket.removeStaleSockets(in: dir) { $0 == 222 }

        #expect(removed == ["com.chappie.mcp.111.sock"])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir))
        #expect(left == ["com.chappie.mcp.222.sock", "com.chappie.mcp.sock", "note.txt"])
    }

    @Test func canConnectIsFalseForMissingAndPlainFile() throws {
        let missing = NSTemporaryDirectory() + "nosock-\(UUID().uuidString)"
        #expect(MCPSocket.canConnect(missing) == false)

        let plain = NSTemporaryDirectory() + "plain-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: plain, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: plain) }
        #expect(MCPSocket.canConnect(plain) == false)   // a leftover file is not a live helper
    }

    @Test func canConnectIsTrueForListeningSocket() throws {
        let path = "/tmp/mcpt-\(getpid())-\(Int.random(in: 1000...9999)).sock"
        let fd = try Self.listen(on: path)
        defer { close(fd); unlink(path) }
        #expect(MCPSocket.canConnect(path))
    }

    static func listen(on path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                _ = bytes.withUnsafeBufferPointer { memcpy(dst, $0.baseAddress!, bytes.count) }
            }
        }
        let bound = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
        return fd
    }
}

@Suite("MCP restart policy")
struct MCPRestartPolicyTests {

    @Test func backoffGrowsThenGivesUp() {
        var policy = MCPRestartPolicy()
        #expect(policy.recordExit(uptime: 0.1) == .restart(after: 1))
        #expect(policy.recordExit(uptime: 0.1) == .restart(after: 2))
        #expect(policy.recordExit(uptime: 0.1) == .restart(after: 4))
        #expect(policy.recordExit(uptime: 0.1) == .restart(after: 8))
        #expect(policy.recordExit(uptime: 0.1) == .giveUp)          // fifth quick failure
    }

    @Test func healthyUptimeStartsFreshSeries() {
        var policy = MCPRestartPolicy()
        _ = policy.recordExit(uptime: 1)
        _ = policy.recordExit(uptime: 1)
        #expect(policy.recordExit(uptime: MCPRestartPolicy.healthyUptime) == .restart(after: 1))
    }

    @Test func justBelowHealthyUptimeStillCountsAsQuick() {
        var policy = MCPRestartPolicy()
        _ = policy.recordExit(uptime: 1)
        #expect(policy.recordExit(uptime: MCPRestartPolicy.healthyUptime - 0.5) == .restart(after: 2))
    }

    @Test func resetRestoresFullBudget() {
        var policy = MCPRestartPolicy()
        for _ in 0..<4 { _ = policy.recordExit(uptime: 0) }
        policy.reset()
        #expect(policy.recordExit(uptime: 0) == .restart(after: 1))
    }

    @Test func staysGivenUpUntilReset() {
        var policy = MCPRestartPolicy()
        for _ in 0..<5 { _ = policy.recordExit(uptime: 0) }
        #expect(policy.recordExit(uptime: 0) == .giveUp)
    }
}

@Suite("MCPToolBridge recovery")
struct MCPToolBridgeRecoveryTests {

    private actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }

    @Test func unreachableWithoutHandlerReportsUnavailable() async {
        let bridge = MCPToolBridge(socketPath: "/tmp/definitely-missing-\(UUID().uuidString).sock")
        let result = await bridge.execute(tool: "git_status")
        #expect(result.contains("unavailable"))
    }

    @Test func handlerRunsOnceAndRetryIsAttempted() async {
        let bridge = MCPToolBridge(socketPath: "/tmp/definitely-missing-\(UUID().uuidString).sock")
        let calls = Counter()
        await bridge.setRecoveryHandler { await calls.bump() }

        let result = await bridge.execute(tool: "git_status")

        #expect(await calls.value() == 1)          // one recovery, not a loop
        #expect(result.contains("unavailable"))     // still nobody there → clear message
    }

    @Test func successfulRecoveryDeliversTheRequest() async throws {
        let path = "/tmp/mcpb-\(getpid())-\(Int.random(in: 1000...9999)).sock"
        let bridge = MCPToolBridge(socketPath: path)
        let server = ServerBox()
        // The "helper" only appears when the bridge asks for recovery.
        await bridge.setRecoveryHandler { server.start(at: path) }
        defer { server.stop(path) }

        let result = await bridge.execute(tool: "git_status")

        #expect(result == "pong")
    }

    /// Minimal stand-in for the helper: answers any request with {"result":"pong"}.
    private final class ServerBox: @unchecked Sendable {
        private var fd: Int32 = -1

        func start(at path: String) {
            guard let listener = try? MCPSocketTests.listen(on: path) else { return }
            fd = listener
            DispatchQueue.global().async {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var header = [UInt8](repeating: 0, count: 4)
                _ = recv(client, &header, 4, MSG_WAITALL)
                let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                var body = [UInt8](repeating: 0, count: length)
                _ = recv(client, &body, length, MSG_WAITALL)
                let reply = Array(#"{"result":"pong"}"#.utf8)
                let n = reply.count
                let head: [UInt8] = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
                _ = send(client, head, 4, 0)
                _ = send(client, reply, n, 0)
            }
        }

        func stop(_ path: String) {
            if fd >= 0 { close(fd) }
            unlink(path)
        }
    }
}
