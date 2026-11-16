// RequestTrace.swift
// ChappieCore
//
// WHY THIS EXISTS: prompt caching lives or dies on one byte of the request prefix. Every cache
// question this project has asked so far ("why did it write 84k again?", "why no read after a
// relaunch?") was answered by inference from token counts, because the log never showed WHAT was
// sent. This prints that.
//
// WHAT IT PRINTS: for each request, a fingerprint of the three parts the provider builds its
// prompt from — the tool list, the system prompt, the messages — plus each part's size. Comparing
// two requests tells you which part changed, in one glance, without a byte dump.
//
// WHY A CANONICAL HASH AND NOT THE BODY BYTES:
// JSONEncoder does NOT serialize a Swift Dictionary in a stable order. Measured 2026-11-16 on one
// struct with a five-key dictionary, three runs of the same binary in one process gave three
// orders; the same code in a new process gets a new seed. Hashing raw body bytes would therefore
// report "changed" on every relaunch even when the content is identical — the very noise this is
// meant to cut through. The fingerprint is taken over a canonical form instead: a dictionary is
// serialized with sorted keys, arrays keep their order, strings are length-prefixed so no two
// neighbours can be confused.
//
// WHAT IT FOUND ON ITS FIRST RUN: the encoder order was not merely unstable between processes, it
// is unstable within one process — two encodings of the same request in the same run produced
// different bytes. That is now fixed at the source (both clients encode with `.sortedKeys`), and
// the raw hash stays in the line to prove it: `raw` must be identical between two requests whose
// `changed` says `none`. If `changed: none` ever appears next to a different `raw`, the ordering
// has come back.
//
// `changed` is the field to read. `none` means every part matched, so the provider reads the
// prefix. `tools, system, msgs` name what moved. `msgs(shrunk: 45→30)` is a re-cut.

import Foundation

// MARK: - RequestFingerprint

/// What one request looks like from the cache's point of view.
public struct RequestFingerprint: Sendable, Equatable {

    /// Number of tools offered.
    public let toolCount: Int
    /// Canonical hash of the tool list, in the order it is sent.
    public let toolsHash: UInt64

    /// Total characters of the system prompt.
    public let systemChars: Int
    /// Canonical hash of the system prompt.
    public let systemHash: UInt64

    /// Number of messages.
    public let messageCount: Int
    /// Canonical hash of the message array, in order.
    public let messagesHash: UInt64

    /// Bytes of the serialized body as it went on the wire.
    public let bodyBytes: Int
    /// Hash of those bytes, which depend on the encoder's dictionary order — see the header.
    public let rawHash: UInt64

    /// Which parts differ from an earlier fingerprint, as short words for the log line.
    ///
    /// "none" is the answer the cache wants: every part equal, so the provider reads the prefix.
    /// "bytes(encoding order)" is the alarming one: the content is identical by this measure while
    /// the wire bytes are not, which means only the encoder's dictionary order moved.
    public func differences(from previous: RequestFingerprint) -> [String] {
        var changed: [String] = []
        if toolCount != previous.toolCount || toolsHash != previous.toolsHash { changed.append("tools") }
        if systemHash != previous.systemHash { changed.append("system") }
        if messageCount < previous.messageCount {
            changed.append("msgs(shrunk: \(previous.messageCount)→\(messageCount))")
        } else if messagesHash != previous.messagesHash {
            changed.append("msgs")
        }

        if changed.isEmpty {
            // Every part matched canonically. Any byte difference left is the encoder's ordering.
            changed.append(rawHash == previous.rawHash ? "none" : "bytes(encoding order only)")
        }
        return changed
    }
}

// MARK: - RequestTrace

/// Prints one line per outgoing request and remembers the previous one to say what changed.
///
/// The counters live in a locked box rather than in free static variables: requests are issued
/// from several tasks and the compiler (rightly) refuses shared mutable global state.
public enum RequestTrace {

    /// Mutable state, guarded by its own lock.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var previous: RequestFingerprint?
        var requestIndex = 0
        var turnIndex = 0
    }

    private static let state = State()

    /// Starts a new turn: resets the per-turn request counter.
    ///
    /// Called by the orchestrator when a user message starts a run, so the log reads
    /// `turn#12 req#3` instead of an endless request count.
    public static func beginTurn() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.turnIndex += 1
        state.requestIndex = 0
        // The previous turn's last request is still the right thing to compare against: the next
        // request is what the cache will match against it. Cleared only on an explicit reset.
    }

    /// Forgets everything. Used by tests and by a provider switch, where an old prefix says
    /// nothing about the new route.
    public static func reset() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.previous = nil
        state.requestIndex = 0
        state.turnIndex = 0
    }

    /// Fingerprints and prints one request body.
    ///
    /// - Parameters:
    ///   - body: the serialized request, exactly as it goes on the wire.
    ///   - route: short label for the wire format, e.g. "native" or "openai".
    public static func log(body: Data?, route: String) {
        guard let body, let fingerprint = fingerprint(of: body) else { return }

        state.lock.lock()
        state.requestIndex += 1
        let index = state.requestIndex
        let turn = state.turnIndex
        let changed = state.previous.map { fingerprint.differences(from: $0) } ?? ["first request of process"]
        state.previous = fingerprint
        state.lock.unlock()

        print("[RequestTrace] \(LogClock.stamp()) \(route) turn#\(turn) req#\(index)"
              + " | sys \(fingerprint.systemChars)ch h=\(hex(fingerprint.systemHash))"
              + " | tools \(fingerprint.toolCount) h=\(hex(fingerprint.toolsHash))"
              + " | msgs \(fingerprint.messageCount) h=\(hex(fingerprint.messagesHash))"
              + " | body \(fingerprint.bodyBytes)B raw=\(hex(fingerprint.rawHash))"
              + " | changed: \(changed.joined(separator: ", "))")
    }

    // MARK: - Fingerprinting

    /// Reads the three prompt parts out of a serialized request body.
    ///
    /// Both wire formats keep them under these names: native Anthropic uses `system` + `messages`
    /// + `tools`, the OpenAI one carries the prompt in `messages[0]` as a system role with `tools`
    /// beside it, which this treats as an empty system part. Nil when the body is not JSON.
    public static func fingerprint(of body: Data) -> RequestFingerprint? {
        guard let root = try? JSONSerialization.jsonObject(with: body),
              let object = root as? [String: Any] else { return nil }

        let tools = object["tools"] as? [Any] ?? []
        var systemCharacters = 0
        if let system = object["system"] {
            systemCharacters = characterCount(system)
        }

        let messages = object["messages"] as? [Any] ?? []

        return RequestFingerprint(
            toolCount: tools.count,
            toolsHash: fnv(canonical(tools)),
            systemChars: systemCharacters,
            systemHash: fnv(canonical(object["system"] ?? "")),
            messageCount: messages.count,
            messagesHash: fnv(canonical(messages)),
            bodyBytes: body.count,
            rawHash: fnv(body)
        )
    }

    /// Characters of a system prompt whatever shape it has: a bare string, or an array of blocks
    /// each carrying `text`.
    static func characterCount(_ value: Any) -> Int {
        if let text = value as? String { return text.count }
        if let blocks = value as? [Any] {
            return blocks.reduce(0) { total, block in
                let text = (block as? [String: Any])?["text"] as? String
                return total + (text?.count ?? 0)
            }
        }
        return 0
    }

    /// A deterministic text form of any JSON value: object keys sorted, arrays in order, strings
    /// length-prefixed. Two equal structures always produce equal text, whatever order the
    /// encoder used and whatever process produced it.
    static func canonical(_ value: Any?) -> String {
        guard let value else { return "n" }

        if value is NSNull { return "n" }

        if let string = value as? String {
            return "s\(string.utf8.count):\(string)"
        }

        // Bool before number: NSNumber bridges both and CFBoolean is the only way to tell.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "b1" : "b0"
            }
            return "d\(String(format: "%.17g", number.doubleValue))"
        }

        if let array = value as? [Any] {
            let parts = array.map { canonical($0) }
            return "a\(array.count):[\(parts.joined(separator: ","))]"
        }

        if let object = value as? [String: Any] {
            let parts = object.keys.sorted().map { key in
                "s\(key.utf8.count):\(key)=\(canonical(object[key]))"
            }
            return "o\(object.count):{\(parts.joined(separator: ","))}"
        }

        return "u"
    }

    static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    static func fnv(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    /// Short, fixed-width hex: enough to compare two lines by eye, short enough to stay readable.
    ///
    /// Eight digits rather than six: these values are compared by a human looking for a match, and
    /// 24 bits would hide a real difference once in sixteen million pairs. Cheap insurance for a
    /// line that only exists to be trusted.
    static func hex(_ hash: UInt64) -> String {
        String(format: "%08llx", hash & 0xffff_ffff)
    }
}
