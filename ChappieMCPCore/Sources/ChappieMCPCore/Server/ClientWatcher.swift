// ClientWatcher.swift
//
// Notices that the app hung up while a tool is still running.
//
// WHY:
// After the request is read the helper used to ignore the socket until it had a response to
// write, so a call the app had already abandoned (Stop button, app quit) kept running to the
// end: a build could burn minutes of CPU after the user cancelled. The app sends nothing after
// its request, so any readability on the socket means "peer closed" (recv returns 0) or an
// error. The watcher then cancels the tool's Task, which stops the child processes.

import Foundation

final class ClientWatcher: @unchecked Sendable {

    private let fd: Int32
    private let onDisconnect: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    private let exited = DispatchSemaphore(value: 0)

    init(fd: Int32, onDisconnect: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.onDisconnect = onDisconnect
    }

    /// Blocks the calling (GCD) thread until `stop()` is called or the peer disconnects.
    func run() {
        defer { exited.signal() }
        while !isStopped {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            guard ready > 0 else { continue }

            if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 || peerClosed() {
                if !isStopped { onDisconnect() }
                return
            }
            // Unexpected extra bytes from the client: not a disconnect, drop them so poll
            // does not spin on them.
            var scratch = [UInt8](repeating: 0, count: 256)
            _ = recv(fd, &scratch, scratch.count, MSG_DONTWAIT)
        }
    }

    /// Asks the loop to end. Call `waitUntilExited()` before closing the descriptor.
    func stop() {
        lock.withLock { stopped = true }
    }

    func waitUntilExited() {
        exited.wait()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func peerClosed() -> Bool {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }
}
