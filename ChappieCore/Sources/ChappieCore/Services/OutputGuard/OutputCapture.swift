// OutputCapture.swift
// ChappieCore
//
// Collects a running command's output without letting memory grow with it.
//
// WHY: the size gate (OutputGuard) can only judge a result after the command finished. Without a
// cap here, `cat huge.log` or `find /` would fill memory long before the gate ever sees the text.
// Beyond the cap only the byte count matters (it goes into the notice), so the middle of the
// stream is simply not stored in memory. The tail window is kept separately so callers can still spot an
// end-of-output sentinel and an exit code at the very end of a huge stream.
//
// SPOOL: with a spool directory, the first chunk that pushes the output past the spool threshold
// opens a file and from then on every byte goes to disk as well (see OutputSpool). The model then
// gets the beginning, the end and the file path instead of a refusal.

import Foundation

public final class OutputCapture: @unchecked Sendable {

    private let lock = NSLock()
    private let headLimit: Int
    private let tailWindow: Int
    private let spoolDirectory: URL?
    private let spoolThreshold: Int
    private var head = Data()
    private var tail = Data()
    private var total = 0
    private var spool: OutputSpool?
    private var spoolFailed = false

    /// - Parameters:
    ///   - spoolDirectory: where the full output goes once it outgrows `spoolThreshold`. Nil = never spool.
    ///   - spoolThreshold: capped by `headLimit`, because the file starts from what the head already holds.
    public init(
        headLimit: Int = OutputGuard.captureCap,
        tailWindow: Int = 1024,
        spoolDirectory: URL? = nil,
        spoolThreshold: Int = OutputGuard.commandLimit
    ) {
        self.headLimit = headLimit
        self.tailWindow = tailWindow
        self.spoolDirectory = spoolDirectory
        self.spoolThreshold = min(spoolThreshold, headLimit)
    }

    /// Stores what fits and counts the rest. Returns the trailing window as text, enough to look
    /// for a sentinel without rescanning (and re-decoding) everything received so far.
    @discardableResult
    public func append(_ chunk: Data) -> String {
        lock.withLock {
            openSpoolIfNeeded(adding: chunk.count)
            spool?.write(chunk)
            total += chunk.count
            if head.count < headLimit { head.append(chunk.prefix(headLimit - head.count)) }
            tail.append(chunk)
            if tail.count > tailWindow { tail = Data(tail.suffix(tailWindow)) }
            return String(decoding: tail, as: UTF8.self)
        }
    }

    /// Called under the lock, before the chunk is counted: the head still equals everything received so far.
    private func openSpoolIfNeeded(adding count: Int) {
        guard spool == nil, !spoolFailed, let spoolDirectory, total + count > spoolThreshold, head.count == total else { return }
        guard let created = OutputSpool.create(in: spoolDirectory) else {
            // One attempt only: a folder that cannot be created now will not fix itself between chunks.
            spoolFailed = true
            return
        }
        created.write(head)
        spool = created
    }

    /// Every byte received, stored or not.
    public var totalBytes: Int { lock.withLock { total } }

    /// True when some of the output was not stored.
    public var isTruncated: Bool { lock.withLock { total > head.count } }

    /// True when the output outgrew the threshold and a file holds all of it.
    public var isSpooled: Bool { lock.withLock { spool != nil } }

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

    /// Closes the file and describes it; nil when nothing was spooled.
    /// - Parameter trailerMarker: the text from which the end of the stream is not the command's own
    ///   output (the shell session appends an exit-code line and a sentinel). It is cut off the file.
    public func closeSpool(trailerMarker: String? = nil, tailBytes: Int) -> OutputSpool.Summary? {
        lock.withLock {
            guard let spool else { return nil }
            var trailerBytes = 0
            var trailerNewlines = 0
            if let trailerMarker {
                let window = String(decoding: tail, as: UTF8.self)
                if let found = window.range(of: trailerMarker, options: .backwards) {
                    let trailer = window[found.lowerBound...]
                    trailerBytes = trailer.utf8.count
                    trailerNewlines = trailer.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
                }
            }
            return spool.finish(dropping: trailerBytes, droppedNewlines: trailerNewlines, tailBytes: tailBytes)
        }
    }
}
