// SocketIOTests.swift
//
// SocketIO bounds every transfer with ONE overall deadline, so a silent or dripping client
// cannot pin a thread forever. Tests use a socketpair, no filesystem socket needed.

import Testing
import Foundation
import Darwin
@testable import ChappieMCPCore

struct SocketIOTests {

    private func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    private func send(_ bytes: [UInt8], on fd: Int32) {
        _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) }
    }

    @Test func readsExactlyTheRequestedBytes() throws {
        let (a, b) = try makePair()
        defer { close(a); close(b) }
        send([1, 2, 3, 4, 5], on: b)

        guard case .data(let bytes) = SocketIO.readExactly(fd: a, count: 5, deadline: Date().addingTimeInterval(2)) else {
            Issue.record("expected data"); return
        }
        #expect(bytes == [1, 2, 3, 4, 5])
    }

    @Test func silentPeerTimesOutAtTheDeadline() throws {
        let (a, b) = try makePair()
        defer { close(a); close(b) }

        let started = Date()
        let result = SocketIO.readExactly(fd: a, count: 4, deadline: Date().addingTimeInterval(0.4))
        guard case .timedOut = result else { Issue.record("expected timeout, got \(result)"); return }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func peerThatClosesEarlyReportsHowMuchArrived() throws {
        let (a, b) = try makePair()
        defer { close(a) }
        send([9, 9], on: b)
        close(b)

        guard case .closed(let received) = SocketIO.readExactly(fd: a, count: 10, deadline: Date().addingTimeInterval(2)) else {
            Issue.record("expected closed"); return
        }
        #expect(received == 2)
    }

    @Test func probeThatConnectsAndLeavesHasZeroBytes() throws {
        // The launcher's readiness probe connects and disconnects without a request: not an error.
        let (a, b) = try makePair()
        defer { close(a) }
        close(b)

        guard case .closed(let received) = SocketIO.readExactly(fd: a, count: 4, deadline: Date().addingTimeInterval(2)) else {
            Issue.record("expected closed"); return
        }
        #expect(received == 0)
    }

    @Test func dripFeedingDoesNotExtendTheDeadline() async throws {
        let (a, b) = try makePair()
        defer { close(a); close(b) }

        // One byte every 0.15 s would satisfy a per-call timeout forever; the overall deadline must win.
        let feeder = Task.detached {
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                var byte: UInt8 = 7
                _ = Darwin.send(b, &byte, 1, MSG_DONTWAIT)
            }
        }
        defer { feeder.cancel() }

        let started = Date()
        let result = SocketIO.readExactly(fd: a, count: 1000, deadline: Date().addingTimeInterval(0.8))
        guard case .timedOut = result else { Issue.record("expected timeout, got \(result)"); return }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func writeAllDeliversEverything() async throws {
        let (a, b) = try makePair()
        defer { close(a); close(b) }
        let payload = Data(repeating: 0x41, count: 500_000)

        // The reader must run concurrently: 500 KB exceeds the socket buffer.
        let reader = Task.detached { () -> Int in
            var total = 0
            var chunk = [UInt8](repeating: 0, count: 65536)
            while total < payload.count {
                let n = recv(b, &chunk, chunk.count, 0)
                if n <= 0 { break }
                total += n
            }
            return total
        }

        let result = SocketIO.writeAll(fd: a, data: payload, deadline: Date().addingTimeInterval(10))
        guard case .done = result else { Issue.record("expected done, got \(result)"); return }
        #expect(await reader.value == payload.count)
    }

    @Test func writeToAPeerThatNeverReadsTimesOut() throws {
        let (a, b) = try makePair()
        defer { close(a); close(b) }

        let started = Date()
        let result = SocketIO.writeAll(fd: a, data: Data(repeating: 0, count: 20_000_000),
                                       deadline: Date().addingTimeInterval(0.6))
        guard case .timedOut = result else { Issue.record("expected timeout, got \(result)"); return }
        #expect(Date().timeIntervalSince(started) < 4)
    }
}
