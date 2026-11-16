// ContextWindowPolicy.swift
// ChappieCore
//
// How many of the newest messages to send, and when to cut them.
//
// WHY AN ALLOWANCE, NOT AN EXACT WINDOW:
// Prompt caching only reads a prefix that is byte-identical to the previous request. Sending
// exactly `limit` messages means every new message evicts the oldest one, so the first message
// after the system prompt changes on every single turn — and the cached prefix ends there.
// The system prompt stays cached; the whole conversation is written again each turn.
//
// HOW MUCH ROOM IS WORTH KEEPING depends on what the route charges:
// - Reading a cached prefix is cheap but paid per request, and it grows with the history.
// - Writing a prefix is expensive and happens on every trim.
// The break-even point is therefore a few multiples of the window, not hundreds.
//
// Measured on RouterAI's native endpoint (RUB per 1M tokens: input 213, cache read 10,
// cache write 266), default window of 30 messages, ~5k tokens added per turn, 3 requests per
// turn — the real agentic pattern:
//   allowance 1×   ( 30 msgs): 6.89 RUB/turn
//   allowance 2×   ( 60 msgs): 4.04 RUB/turn
//   allowance 3×   ( 90 msgs): 3.61 RUB/turn   ← minimum
//   allowance 4×   (120 msgs): 3.64 RUB/turn
//   allowance 10×  (300 msgs): 4.86 RUB/turn
//   allowance 55×  (1M  msgs): 17.30 RUB/turn
// The curve is flat between 2× and 4×, so being off by a factor of two costs little;
// past 10× the read cost starts to dominate.
//
// Early live measurement on the same gateway, 9 growing turns, ~250-token messages, small slack:
//   exact window : wrote 160026 tokens, read  22602  → 43.94 RUB
//   slack of 4   : wrote   4744 tokens, read 188468  →  6.53 RUB
// Over 15 user turns of 3 requests each: 3.42 → 1.87 RUB per turn.
//
// Cost of the allowance: a request may carry more than `limit` messages — up to three times the
// configured window on a cache-reading route. That overshoot is paid once per trim cycle instead
// of rewriting the whole conversation every turn.
//
// Cutting may leave the history starting with an assistant turn. Verified: the API accepts it.
//
// WHY THE TRIM NEEDS AN ANCHOR, NOT JUST A LIMIT:
// The caller hands in the whole loaded history, which grows by a couple of messages every turn.
// Deciding purely on that length makes the window slide instead of standing still: 112 messages
// cut to the newest 30, then 114 cut to the newest 30 — the first message of the window moves
// two places forward and the cached prefix dies at its first byte.
// Measured live: 112 → 30 at 18:55 and 114 → 30 a minute later, both full prefix writes,
// 23.86 RUB per turn against 2.29 RUB for a read.
// So the policy remembers how many leading messages it dropped last time and starts from there.
// The window then grows forward from a fixed point for many turns — which is the whole point.

import Foundation

// MARK: - PromptCacheProfile

/// What a client knows about its provider's prefix cache.
///
/// WHY ON THE CLIENT, NOT ON THE CONFIG: the decision depends on the route the request will
/// actually take, and the route is chosen per request by `AIClientFactory` — the same provider
/// preset serves Claude models over the native protocol and everything else over the OpenAI one.
/// Asking the client avoids duplicating that routing rule here.
public struct PromptCacheProfile: Sendable, Equatable {

    /// How long a written prefix stays readable without being refreshed by a read.
    ///
    /// Used to tell a warm cache from a cold one: after a long pause the old prefix is gone, so
    /// keeping the history long protects nothing and only makes the next write bigger.
    public let ttl: TimeInterval

    public init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// Native Anthropic protocol with the 1h extended-cache-ttl beta header enabled.
    ///
    /// WHY 1h: the default 5-minute TTL expires inside a normal working session, and the whole
    /// conversation is rewritten each time it does.
    public static let anthropicOneHour = PromptCacheProfile(ttl: 3600)
}

// MARK: - ContextWindowAllowance

/// How much room beyond the configured window a route is allowed to use.
public enum ContextWindowAllowance: Sendable, Equatable {

    /// Exactly `limit` messages. Correct when there is no prefix worth protecting: a cold cache,
    /// a long pause, or a route that does not read a cache at all.
    case exact

    /// A measured small slack. Kept for routes that accept `cache_control` but whose reads were
    /// never confirmed — the overshoot is bounded and the cost was measured.
    case slack

    /// Up to three times `limit`, for a route whose cache demonstrably reads the whole history.
    /// Three is the measured minimum of the cost curve; see the header of this file.
    case triple
}

// MARK: - ContextWindowPolicy

public enum ContextWindowPolicy {

    /// Multiplier used by `.triple`.
    public static let tripleMultiplier = 3

    /// Small allowance kept for providers whose cache reads are unverified.
    ///
    /// Proportional so it stays meaningful for big windows, with a floor of 4 — measured as the
    /// sweet spot at the default limit of 30 (slack 8 and 12 were slightly worse, slack 2
    /// noticeably worse).
    public static func slack(for limit: Int) -> Int {
        guard limit != Int.max else { return 0 }
        return max(4, limit / 8)
    }

    /// How many messages the history may hold before a trim happens, in this mode.
    ///
    /// `Int.max` means "never trim".
    public static func allowance(limit: Int, mode: ContextWindowAllowance) -> Int {
        guard limit != Int.max else { return Int.max }
        switch mode {
        case .exact:
            return limit
        case .slack:
            return limit + slack(for: limit)
        case .triple:
            // The window is clamped to 1000 by ThreadSettings, so this cannot overflow in
            // practice; the guard keeps the arithmetic total anyway.
            guard limit <= Int.max / tripleMultiplier else { return Int.max }
            return limit * tripleMultiplier
        }
    }

    /// Whether a prefix written at `lastRequestAt` can still be read at `now`.
    ///
    /// Pure so the threshold can be tested without an actor. Returns false when there is no
    /// profile (the route does not cache) or no recorded request (nothing was ever written).
    ///
    /// The margin is deliberate: a request that starts a minute before nominal expiry cannot
    /// count on a prefix that another turn's write may have pushed past it.
    public static func cacheIsWarm(
        lastRequestAt: Date?,
        now: Date,
        profile: PromptCacheProfile?,
        margin: Double = cacheWarmthMargin
    ) -> Bool {
        guard let profile, let lastRequestAt else { return false }
        return now.timeIntervalSince(lastRequestAt) < profile.ttl * margin
    }

    /// A safety margin below the nominal TTL.
    public static let cacheWarmthMargin: Double = 0.9

    /// The newest messages to send, with the trim decision reported for the log.
    ///
    /// This is the anchor-free form: it decides on the length of what it is given, so a caller
    /// that passes the whole growing history gets a sliding window. Kept for its tests and for
    /// callers that hold nothing between turns; the orchestrator uses `slice` below.
    public static func trim(
        _ history: [AIMessage],
        limit: Int,
        mode: ContextWindowAllowance = .slack
    ) -> (messages: [AIMessage], trimmedFrom: Int?) {
        let result = slice(history, limit: limit, mode: mode)
        return (result.messages, result.trimmedFrom)
    }

    /// One turn's window: what to send and which message it starts at.
    public struct Slice: Sendable {
        /// Messages to send, in order.
        public let messages: [AIMessage]
        /// Length of the history this was cut from, or nil when nothing was cut.
        public let trimmedFrom: Int?
        /// Signature of the first message sent this turn — the anchor to look up next turn so the
        /// window stands still instead of sliding. Nil when there is nothing to send.
        public let anchor: String?
    }

    /// The newest messages to send, measured from a remembered anchor.
    ///
    /// `anchorSignature` identifies the message the window started at last turn. While the window
    /// from there to the end of the history fits the mode's allowance, the same message starts the
    /// window again and the prefix is unchanged — that is what the provider reads from cache.
    /// Once the window outgrows the allowance it is cut back to exactly `limit` and a new anchor
    /// is returned, which costs one prefix write and then buys many cheap turns.
    ///
    /// WHY THE SEARCH IS DETERMINISTIC RATHER THAN CLEVER: two messages can share a signature
    /// (identical role and text), so the lookup may land on an earlier copy than the one intended.
    /// That is harmless, because each turn re-stores the signature of whatever it actually sent —
    /// the choice is stable from turn to turn, and stability is the only thing the cache needs.
    ///
    /// A stale anchor (history shrank, another thread, a relaunch onto a shorter chat) is
    /// discarded rather than trusted: an anchor near the end would send almost nothing.
    public static func slice(
        _ history: [AIMessage],
        limit: Int,
        mode: ContextWindowAllowance = .slack,
        anchorSignature: String? = nil
    ) -> Slice {
        // Signatures are computed once for the whole history, so that a repeated message is told
        // apart from its earlier copies. See WindowAnchor.signatures(for:).
        let signatures = WindowAnchor.signatures(for: history)

        func anchorAt(_ index: Int) -> String? {
            signatures.indices.contains(index) ? signatures[index] : nil
        }

        guard limit != Int.max else {
            return Slice(messages: history, trimmedFrom: nil, anchor: anchorAt(0))
        }
        // A history that already fits is sent whole; the anchor is its first message, so that a
        // window which starts growing next turn grows from the same place.
        guard history.count > limit else {
            return Slice(messages: history, trimmedFrom: nil, anchor: anchorAt(0))
        }

        // Where does the window start? At the remembered message, if it is still in the history
        // and still far enough back to be worth starting at.
        var start = 0
        if let anchorSignature,
           let index = signatures.firstIndex(of: anchorSignature),
           history.count - index >= limit {
            start = index
        }

        let loaded = history.count - start

        guard loaded > allowance(limit: limit, mode: mode) else {
            return Slice(
                messages: Array(history.dropFirst(start)),
                trimmedFrom: nil,
                anchor: anchorAt(start)
            )
        }

        let newStart = history.count - limit
        return Slice(
            messages: Array(history.suffix(limit)),
            trimmedFrom: history.count,
            anchor: anchorAt(newStart)
        )
    }
}

// MARK: - AIClientProtocol

public extension AIClientProtocol {

    /// nil when the route has no prefix cache this app can rely on.
    ///
    /// Default is nil — a client that reads a cache must say so explicitly, because the wider
    /// allowance it unlocks is only worth its overshoot when the reads are real.
    var promptCacheProfile: PromptCacheProfile? { nil }
}
