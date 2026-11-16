// LogClock.swift
// ChappieCore
//
// A timestamp for every log line that matters across processes.
//
// WHY: the cache questions this project keeps asking are all about TIME and ORDER — "did the
// request go out before the TTL expired", "how long between these two turns", "which of the six
// requests in this turn wrote the prefix". Without a stamp two lines from different turns look
// identical, and a log copied out of Console loses whatever ordering the app printed it in.
//
// Milliseconds, not seconds: a turn fires six requests a few hundred milliseconds apart.

import Foundation

public enum LogClock {

    private static let lock = NSLock()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// "14:03:27.918" — wall clock, local timezone.
    ///
    /// DateFormatter is not safe to share across threads and the orchestrator logs from an actor
    /// while a client logs from the network path, so the formatter is locked rather than copied.
    public static func stamp(_ date: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    /// First eight characters of a UUID — enough to tell threads apart in a log, short enough to
    /// keep a line readable.
    public static func short(_ id: UUID?) -> String {
        guard let id else { return "none" }
        return String(id.uuidString.prefix(8))
    }
}
