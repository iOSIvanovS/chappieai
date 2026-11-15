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
    /// Returns the input untouched while it fits within the mode's allowance; once it grows past
    /// that, it is cut back to exactly `limit`. The prefix therefore survives several turns
    /// unchanged, which is what lets the provider read its cache instead of rewriting it.
    public static func trim(
        _ history: [AIMessage],
        limit: Int,
        mode: ContextWindowAllowance = .slack
    ) -> (messages: [AIMessage], trimmedFrom: Int?) {
        guard limit != Int.max, history.count > limit else {
            return (history, nil)
        }
        guard history.count > allowance(limit: limit, mode: mode) else {
            return (history, nil)
        }
        return (Array(history.suffix(limit)), history.count)
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
