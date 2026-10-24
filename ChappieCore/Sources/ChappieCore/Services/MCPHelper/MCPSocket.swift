// MCPSocket.swift
// ChappieCore
//
// Single source of truth for where the ChappieMCP helper's Unix socket lives.
//
// Why one socket per app instance (path contains the app PID): a second Chappie instance
// (e.g. release + debug build) used to delete the first one's socket on helper start-up.
// With the PID in the name the instances cannot touch each other, and a socket whose PID
// is dead is provably stale and safe to remove.

import Foundation

public enum MCPSocket {

    public static let directory = "/tmp"
    static let prefix = "com.chappie.mcp."
    static let suffix = ".sock"

    /// Socket path owned by the Chappie app process with the given PID.
    public static func path(forPID pid: Int32) -> String {
        "\(directory)/\(prefix)\(pid)\(suffix)"
    }

    /// Socket path for this very process — what the launcher binds and the bridge dials.
    public static var currentProcessPath: String { path(forPID: getpid()) }

    /// Extracts the owner PID from a socket file name; nil for anything that is not
    /// `com.chappie.mcp.<digits>.sock` (this deliberately excludes the legacy fixed-name
    /// socket, which an older installed app may still be using).
    static func pid(fromFileName name: String) -> Int32? {
        guard name.count > prefix.count + suffix.count,
              name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !middle.isEmpty, middle.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int32(middle)
    }

    /// Names (from `names`) of sockets whose owner process is gone. Pure so it can be tested.
    static func staleSocketNames(among names: [String], ownPID: Int32,
                                 isAlive: (Int32) -> Bool) -> [String] {
        names.filter { name in
            guard let pid = pid(fromFileName: name), pid != ownPID else { return false }
            return !isAlive(pid)
        }
    }

    /// EPERM means the process exists but belongs to someone else — still alive.
    public static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Removes socket files left behind by app instances that died without cleaning up.
    @discardableResult
    public static func removeStaleSockets(
        in dir: String = MCPSocket.directory,
        isAlive: (Int32) -> Bool = MCPSocket.processExists
    ) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let stale = staleSocketNames(among: names, ownPID: getpid(), isAlive: isAlive)
        for name in stale {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(name)")
        }
        return stale
    }

    /// True if something accepts connections on the socket. A leftover file of a dead
    /// helper fails here (ECONNREFUSED), unlike a plain file-exists check.
    public static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                _ = bytes.withUnsafeBufferPointer { memcpy(dst, $0.baseAddress!, bytes.count) }
            }
        }
        let result = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
