// SocketIO.swift
//
// WHY THIS FILE:
// Blocking socket reads/writes with ONE overall deadline per operation.
// A plain recv(MSG_WAITALL) waits forever for a silent client, and a per-call
// SO_RCVTIMEO can be defeated by a client that drips one byte every few seconds.
// poll() with the remaining time budget bounds the whole transfer.
//
// These functions block the calling thread, so they must run on a dedicated
// DispatchQueue and never on Swift concurrency's cooperative pool.

import Foundation

enum SocketIO {

    enum ReadResult {
        case data([UInt8])
        /// Peer closed the connection after `received` bytes (0 = connected and left at once).
        case closed(received: Int)
        case timedOut
        case failed(String)
    }

    enum WriteResult {
        case done
        case timedOut
        case failed(String)
    }

    /// Reads exactly `count` bytes or reports why it could not, never waiting past `deadline`.
    static func readExactly(fd: Int32, count: Int, deadline: Date) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0

        while received < count {
            guard let waitMs = remainingMilliseconds(until: deadline) else { return .timedOut }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, waitMs)
            if ready == 0 { return .timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                return .failed(String(cString: strerror(errno)))
            }

            let offset = received
            let n = buffer.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress! + offset, count - offset, 0)
            }
            if n == 0 { return .closed(received: received) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failed(String(cString: strerror(errno)))
            }
            received += n
        }
        return .data(buffer)
    }

    /// Writes all of `data`, giving up at `deadline` (a client that never reads must not pin a thread).
    static func writeAll(fd: Int32, data: Data, deadline: Date) -> WriteResult {
        var sent = 0
        let total = data.count

        // macOS ignores MSG_DONTWAIT on send(): a blocking socket still blocks until the whole
        // buffer is queued, so a client that never reads would pin this thread past the deadline
        // (reproduced: 20 MB to a silent peer never returned). O_NONBLOCK is honoured, so set it
        // for the duration of the write and restore the original flags afterwards.
        let originalFlags = fcntl(fd, F_GETFL)
        if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) }
        defer { if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags) } }

        while sent < total {
            guard let waitMs = remainingMilliseconds(until: deadline) else { return .timedOut }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, waitMs)
            if ready == 0 { return .timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                return .failed(String(cString: strerror(errno)))
            }

            let offset = sent
            let n = data.withUnsafeBytes {
                send(fd, $0.baseAddress! + offset, total - offset, 0)
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failed(String(cString: strerror(errno)))
            }
            sent += n
        }
        return .done
    }

    /// Milliseconds left until `deadline`, or nil when it has already passed.
    private static func remainingMilliseconds(until deadline: Date) -> Int32? {
        let ms = deadline.timeIntervalSinceNow * 1000
        guard ms >= 1 else { return nil }
        return Int32(min(ms, Double(Int32.max)))
    }
}
