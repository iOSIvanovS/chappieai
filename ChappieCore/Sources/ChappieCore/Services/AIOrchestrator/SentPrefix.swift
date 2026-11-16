// SentPrefix.swift
// ChappieCore
//
// A fingerprint of the request prefix a turn sent, so the next turn can tell whether the provider
// will READ that prefix from cache or WRITE a new one.
//
// WHY THIS EXISTS: the whole context-window design comes down to one binary question — will the
// next request reuse the cached prefix? Until now it was guessed from two proxies: how long ago
// the last request went out (a cache can expire) and whether the window still starts on the same
// message (a window can slide). Both are approximations. The system prompt is rebuilt every turn
// from memory, project settings and the tool list, and any change there moves the FIRST byte of
// the prompt — which invalidates everything after it, however carefully the window was anchored.
//
// So the prompt itself is compared instead of guessed about. If the tools and the system prompt
// hash the same as when the last request went out, the provider reads; if not, it writes, and the
// window is cut to `limit` immediately rather than sending an oversized prompt that will be
// rewritten from scratch at full price.
//
// WHY A HASH OVER THE CONTENT AND NOT OVER THE WIRE BYTES: JSONEncoder's dictionary order was
// unstable between processes (see RequestTrace), so raw bytes reported "different" after every
// relaunch even when nothing had changed. The parts are encoded with `.sortedKeys` here, which
// makes them byte-identical in every process and every build.
//
// WHY THE MESSAGE COUNT IS STORED TOO: hashing "everything current except the newest message" can
// never match. The previous request is always a strict prefix of the current one — turn N sent
// [head, a, b, c], turn N+1 sends [head, a, b, c, answer, prompt] — so a hash taken over a
// different number of items compares two different things. Storing the count lets the next turn
// hash exactly the same slice and compare like with like.

import Foundation

// MARK: - SentPrefix

/// What one request's prefix looked like, in a form that survives a relaunch.
///
/// `headHash` covers the tools and the system prompt — the part that is rebuilt from live state
/// and therefore the part that changes without the conversation changing. `prefixHash` covers the
/// head plus the first `messageCount` messages, so a window that slid or a message that was
/// rewritten shows up as well.
public struct SentPrefix: Sendable, Equatable {

    /// Hash of tools + system prompt.
    public let headHash: UInt64

    /// Hash of tools + system prompt + the first `messageCount` messages.
    public let prefixHash: UInt64

    /// How many messages the request carried. The next turn hashes this many of its own.
    public let messageCount: Int

    public init(headHash: UInt64, prefixHash: UInt64, messageCount: Int) {
        self.headHash = headHash
        self.prefixHash = prefixHash
        self.messageCount = messageCount
    }

    /// A single string for storage: two hex hashes and a count, cheap to write and to read back.
    public var rawValue: String {
        "\(String(format: "%016llx", headHash))"
            + "|\(String(format: "%016llx", prefixHash))"
            + "|\(messageCount)"
    }

    /// Parses `rawValue`. Nil for anything that is not three well-formed fields, so a corrupt or
    /// older entry is treated as "nothing known" rather than as a wrong answer.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let head = UInt64(parts[0], radix: 16),
              let prefix = UInt64(parts[1], radix: 16),
              let count = Int(parts[2]), count >= 0
        else { return nil }
        self.init(headHash: head, prefixHash: prefix, messageCount: count)
    }
}

// MARK: - PrefixFingerprint

public enum PrefixFingerprint {

    /// What the comparison says about the provider's cache for the turn about to be sent.
    public enum Verdict: Sendable, Equatable {

        /// Nothing was recorded, so nothing can be claimed. Treated as "will write".
        case unknown

        /// Tools, system prompt and the overlapping messages all match: the prefix is readable.
        case kept

        /// The tools or the system prompt changed. Everything after the first byte is new.
        case headChanged

        /// The head matches but the messages the two requests share do not — the window moved, or
        /// an earlier message was rewritten.
        case messagesChanged

        /// Word for the log line.
        public var label: String {
            switch self {
            case .unknown:        return "unknown"
            case .kept:           return "kept"
            case .headChanged:    return "changed(head)"
            case .messagesChanged: return "changed(msgs)"
            }
        }
    }

    // MARK: Building

    /// The prefix of a request that is about to go out.
    public static func make(tools: [AITool], system: String, messages: [AIMessage]) -> SentPrefix {
        SentPrefix(
            headHash: headHash(tools: tools, system: system),
            prefixHash: prefixHash(tools: tools, system: system, messages: messages),
            messageCount: messages.count
        )
    }

    /// Hash of the two parts that are rebuilt from live state on every turn.
    ///
    /// Cheap to take on its own, which matters: this is the half that can be compared without
    /// knowing what the window will be, so it decides whether a wide window is even worth trying.
    public static func headHash(tools: [AITool], system: String) -> UInt64 {
        var data = Data()
        append(encoded(tools), to: &data)
        append(Data(system.utf8), to: &data)
        return RequestTrace.fnv(data)
    }

    /// Hash of the head plus a given run of messages.
    public static func prefixHash(tools: [AITool], system: String, messages: [AIMessage]) -> UInt64 {
        var data = Data()
        append(encoded(tools), to: &data)
        append(Data(system.utf8), to: &data)
        for message in messages { append(encoded(message), to: &data) }
        return RequestTrace.fnv(data)
    }

    // MARK: Comparing

    /// Whether the prefix of this request can still be read from the provider's cache.
    public static func verdict(
        stored: SentPrefix?,
        tools: [AITool],
        system: String,
        messages: [AIMessage]
    ) -> Verdict {
        guard let stored else { return .unknown }

        guard headHash(tools: tools, system: system) == stored.headHash else {
            return .headChanged
        }

        // The previous request is a prefix of this one only as far as it reached. A history that
        // shrank below that (another thread, a truncated chat) cannot be compared like with like.
        guard messages.count >= stored.messageCount else { return .messagesChanged }

        let overlap = Array(messages.prefix(stored.messageCount))
        let prefix = prefixHash(tools: tools, system: system, messages: overlap)
        return prefix == stored.prefixHash ? .kept : .messagesChanged
    }

    // MARK: Encoding

    /// Deterministic bytes for a value.
    ///
    /// `.sortedKeys` is the whole point: without it a Swift Dictionary is written in an order
    /// seeded per process, so the same tool schema hashed differently after every relaunch.
    static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// Appends a piece with its length, so two pieces can never run together into the same bytes
    /// as a different pair ("ab"+"c" must not equal "a"+"bc").
    private static func append(_ piece: Data, to data: inout Data) {
        var length = UInt64(piece.count)
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(piece)
    }
}
