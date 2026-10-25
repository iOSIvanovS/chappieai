// OutputCapture.swift
// ChappieCore
//
// Collects a running command's output without letting memory grow with it.
//
// WHY: the size gate (OutputGuard) can only judge a result after the command finished. Without a
// cap here, `cat huge.log` or `find /` would fill memory long before the gate ever sees the text.
// Beyond the cap only the byte count matters (it goes into the notice), so the middle of the
// stream is simply not stored. The tail window is kept separately so callers can still spot an
// end-of-output sentinel and an exit code at the very end of a huge stream.

import Foundation

public final class OutputCapture: @unchecked Sendable {

    private let lock = NSLock()
    private let headLimit: Int
    private let tailWindow: Int
    private var head = Data()
    private var tail = Data()
    private var total = 0

    public init(headLimit: Int = OutputGuard.captureCap, tailWindow: Int = 1024) {
        self.headLimit = headLimit
        self.tailWindow = tailWindow
    }

    /// Stores what fits and counts the rest. Returns the trailing window as text, enough to look
    /// for a sentinel without rescanning (and re-decoding) everything received so far.
    @discardableResult
    public func append(_ chunk: Data) -> String {
        lock.withLock {
            total += chunk.count
            if head.count < headLimit { head.append(chunk.prefix(headLimit - head.count)) }
            tail.append(chunk)
            if tail.count > tailWindow { tail = Data(tail.suffix(tailWindow)) }
            return String(decoding: tail, as: UTF8.self)
        }
    }

    /// Every byte received, stored or not.
    public var totalBytes: Int { lock.withLock { total } }

    /// True when some of the output was not stored.
    public var isTruncated: Bool { lock.withLock { total > head.count } }

    /// The stored beginning. Lossy decoding: a cut inside a multi-byte character must not drop the text.
    public var headText: String { lock.withLock { String(decoding: head, as: UTF8.self) } }

    /// The last bytes of the stream (up to `tailWindow`).
    public var tailText: String { lock.withLock { String(decoding: tail, as: UTF8.self) } }

    /// Stored text plus, when truncated, the marker OutputGuard uses to learn the real size.
    public func text() -> String {
        lock.withLock {
            let stored = String(decoding: head, as: UTF8.self)
            guard total > head.count else { return stored }
            return stored + "\n" + OutputGuard.truncationMarker(totalBytes: total)
        }
    }
}
