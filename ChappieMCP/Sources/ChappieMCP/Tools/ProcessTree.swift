// ProcessTree.swift
//
// Stops a child process together with everything it spawned.
//
// WHY A TREE, NOT process.terminate():
// xcodebuild, bash -l and ssh start their own children (compilers, test hosts, remote commands).
// SIGTERM to the parent alone leaves them running, and a parent that traps or ignores SIGTERM
// survives too. So we snapshot the descendants BEFORE signalling (once the parent dies its
// children are re-parented to launchd and can no longer be found), ask politely with SIGTERM,
// and SIGKILL whatever is still alive after a grace period.
//
// KEEP IN SYNC: ChappieCore and ChappieMCP are separate targets and cannot share code, so this
// file exists twice (same trick as PathGuard). ProcessTreeTests fails if the copies drift apart.

import Foundation
import Darwin

enum ProcessTree {

    /// A pid plus its start time. The start time makes a delayed SIGKILL safe against pid reuse.
    struct Identity: Hashable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    /// Time between the polite SIGTERM and the forced SIGKILL.
    static let defaultGrace: TimeInterval = 2

    /// All descendants of `pid` (children, grandchildren, ...), depth-first.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 512)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).flatMap { [$0] + descendants(of: $0) }
    }

    static func identity(of pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Identity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    /// Non-blocking: sends SIGTERM to the root and its descendants now, schedules SIGKILL for the
    /// survivors. Safe to call from any thread, including the main thread.
    static func terminate(rootPid: pid_t, grace: TimeInterval = defaultGrace) {
        guard rootPid > 1 else { return }

        let victims = [rootPid] + descendants(of: rootPid)
        let identities = victims.compactMap { identity(of: $0) }
        for pid in victims { kill(pid, SIGTERM) }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            var targets = identities
            // Whatever the tree started after the snapshot, while the root is still the same process.
            if let root = identities.first(where: { $0.pid == rootPid }), identity(of: rootPid) == root {
                for pid in descendants(of: rootPid) {
                    if let found = identity(of: pid), !targets.contains(found) { targets.append(found) }
                }
            }
            for target in targets where identity(of: target.pid) == target {
                kill(target.pid, SIGKILL)
            }
        }
    }

    /// True while the process exists (a zombie that nobody reaped yet still counts).
    static func exists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Hands a "stop" request (user cancel or timeout) to a process that may not have started yet.
/// Cancellation can arrive before `Process.run()` returns, so the request is remembered and
/// applied the moment the pid is attached.
final class ProcessCanceller: @unchecked Sendable {

    enum Reason: Sendable { case cancelled, timedOut }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var reason: Reason?

    /// Why the process was stopped, nil if nobody asked.
    var stopReason: Reason? { lock.withLock { reason } }

    /// Call right after the process was launched.
    func attach(pid: pid_t) {
        let alreadyStopped: Bool = lock.withLock {
            self.pid = pid
            return reason != nil
        }
        if alreadyStopped { ProcessTree.terminate(rootPid: pid) }
    }

    /// First reason wins; later calls (e.g. a timeout after a cancel) do nothing.
    func stop(_ why: Reason) {
        let target: pid_t = lock.withLock {
            guard reason == nil else { return 0 }
            reason = why
            return pid
        }
        if target > 0 { ProcessTree.terminate(rootPid: target) }
    }
}
