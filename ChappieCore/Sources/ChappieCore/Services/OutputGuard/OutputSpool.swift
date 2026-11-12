// OutputSpool.swift
// ChappieCore
//
// Disk copy of a command's full output.
//
// WHY: a build or a test run can print megabytes. Refusing it (the old notice) leaves the model blind,
// and keeping it in the context is too expensive. The full text goes to a file instead; the model gets
// the beginning, the end and the path, and searches the middle itself (grep, sed, tail in the terminal).
//
// Not thread-safe on its own: OutputCapture owns it and calls it only under its lock.
// Files live in the temporary folder, are readable by the owner only (output can hold secrets) and
// are removed by age and by total folder size the first time a folder is used in a process.

import Foundation

public final class OutputSpool: @unchecked Sendable {

    // MARK: - Limits

    /// A runaway command must not fill the disk: past this the file stops growing.
    public static let maxFileBytes = 256 * 1024 * 1024
    /// Files older than this are removed.
    public static let maxAge: TimeInterval = 24 * 3600
    /// When the folder is bigger, the oldest files go first.
    public static let maxFolderBytes = 1024 * 1024 * 1024
    /// Recent files are never evicted by size: one of them may belong to a command still running.
    private static let evictionGrace: TimeInterval = 3600

    public static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chappie-terminal-output", isDirectory: true)
    }

    // MARK: - Summary

    /// What is left after the spool is closed.
    public struct Summary: Sendable {
        public let url: URL
        public let bytes: Int
        public let lines: Int
        /// The file does not hold everything: the size cap was hit or a write failed.
        public let isIncomplete: Bool
        /// Last lines of the file, cut at a line start.
        public let tailText: String
    }

    // MARK: - State

    public let url: URL
    private let limit: Int
    private var handle: FileHandle?
    private var bytesWritten = 0
    private var newlineCount = 0
    private var incomplete = false
    private var summary: Summary?

    private init(url: URL, handle: FileHandle, limit: Int) {
        self.url = url
        self.handle = handle
        self.limit = limit
    }

    // MARK: - Create

    /// Nil when the folder or the file cannot be created: the caller then falls back to memory only.
    static func create(in directory: URL, limit: Int = maxFileBytes) -> OutputSpool? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { return nil }
        CleanupState.shared.cleanOnce(directory)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "out-\(stamp)-\(UUID().uuidString.prefix(8)).log"
        let fileURL = directory.appendingPathComponent(name)
        guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        return OutputSpool(url: fileURL, handle: handle, limit: limit)
    }

    // MARK: - Write

    func write(_ data: Data) {
        guard let handle, !data.isEmpty else { return }
        let room = limit - bytesWritten
        guard room > 0 else { incomplete = true; return }
        let part = data.count > room ? data.prefix(room) : data
        do {
            try handle.write(contentsOf: part)
        } catch {
            // Disk full or file gone: keep what is there, mark it incomplete, stop writing.
            incomplete = true
            try? handle.close()
            self.handle = nil
            return
        }
        bytesWritten += part.count
        newlineCount += Self.newlines(in: part)
        if part.count < data.count { incomplete = true }
    }

    // MARK: - Finish

    /// Closes the file and describes it. `trailerBytes` are the bytes at the end that are not the
    /// command's output (the exit-code line and the sentinel the shell session appends); they are cut off.
    /// Safe to call again: the first answer is kept.
    func finish(dropping trailerBytes: Int, droppedNewlines: Int, tailBytes: Int) -> Summary {
        if let summary { return summary }
        var size = bytesWritten
        var lines = newlineCount
        if let handle {
            if !incomplete, trailerBytes > 0, trailerBytes <= bytesWritten {
                size -= trailerBytes
                lines -= droppedNewlines
                try? handle.truncate(atOffset: UInt64(size))
            }
            try? handle.close()
            self.handle = nil
        } else {
            incomplete = true
        }

        let tail = Self.readTail(of: url, size: size, maxBytes: tailBytes)
        if let last = tail.last, last != 0x0A { lines += 1 }
        let result = Summary(
            url: url, bytes: size, lines: max(lines, 0), isIncomplete: incomplete,
            tailText: String(decoding: tail, as: UTF8.self)
        )
        summary = result
        return result
    }

    // MARK: - Helpers

    private static func newlines(in data: Data) -> Int {
        data.withUnsafeBytes { raw in
            var count = 0
            for byte in raw where byte == 0x0A { count += 1 }
            return count
        }
    }

    /// The end of the file starting at a line boundary, so the model never sees half a line or half a character.
    private static func readTail(of url: URL, size: Int, maxBytes: Int) -> Data {
        guard size > 0, let reader = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? reader.close() }
        let start = max(0, size - maxBytes)
        try? reader.seek(toOffset: UInt64(start))
        var data = (try? reader.read(upToCount: maxBytes)) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A), newline + 1 < data.endIndex {
            data = data.suffix(from: newline + 1)
        }
        return data
    }

    // MARK: - Cleanup

    /// Each folder is cleaned once per process: the first spool of a run pays for it, the rest do not.
    private final class CleanupState: @unchecked Sendable {
        static let shared = CleanupState()
        private let lock = NSLock()
        private var cleaned = Set<String>()

        func cleanOnce(_ directory: URL) {
            let first = lock.withLock { cleaned.insert(directory.path).inserted }
            if first { OutputSpool.cleanup(directory, now: Date()) }
        }
    }

    /// Removes files older than `maxAge`, then the oldest ones while the folder exceeds `maxFolderBytes`.
    static func cleanup(_ directory: URL, now: Date) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }

        var survivors: [(url: URL, date: Date, size: Int)] = []
        for fileURL in urls where fileURL.pathExtension == "log" {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? now
            if now.timeIntervalSince(date) > maxAge {
                try? manager.removeItem(at: fileURL)
            } else {
                survivors.append((fileURL, date, values?.fileSize ?? 0))
            }
        }

        var total = survivors.reduce(0) { $0 + $1.size }
        for file in survivors.sorted(by: { $0.date < $1.date }) where total > maxFolderBytes {
            guard now.timeIntervalSince(file.date) > evictionGrace else { continue }
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
