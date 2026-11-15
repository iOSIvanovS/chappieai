// ContextWindowPolicy.swift
// ChappieCore
//
// How many of the newest messages to send, and when to cut them.
//
// WHY A SLACK, NOT AN EXACT WINDOW:
// Prompt caching only reads a prefix that is byte-identical to the previous request. Sending
// exactly `limit` messages means every new message evicts the oldest one, so the first message
// after the system prompt changes on every single turn — and the cached prefix ends there.
// The system prompt stays cached; the whole conversation is written again each turn.
//
// Measured on RouterAI's native endpoint, 9 growing turns, 30-message limit, ~250-token messages:
//   exact window : wrote 160026 tokens, read  22602  → 43.94 RUB
//   slack of 4   : wrote   4744 tokens, read 188468  →  6.53 RUB
// Over 15 user turns of 3 requests each (the real agentic pattern): 3.42 → 1.87 RUB per turn.
//
// Cost of the slack: a request carries up to `limit + slack` messages instead of `limit`.
// That is a bounded overshoot of the configured window, paid once per trim cycle instead of
// rewriting the whole conversation every turn.
//
// Cutting may leave the history starting with an assistant turn. Verified: the API accepts it.

import Foundation

public enum ContextWindowPolicy {

    /// Extra messages kept beyond the limit before trimming back to it.
    ///
    /// Proportional so the slack stays meaningful for big windows, with a floor of 4 — measured
    /// as the sweet spot at the default limit of 30 (slack 8 and 12 were slightly worse, slack 2
    /// noticeably worse).
    public static func slack(for limit: Int) -> Int {
        guard limit != Int.max else { return 0 }
        return max(4, limit / 8)
    }

    /// The newest messages to send, with the trim decision reported for the log.
    ///
    /// Returns the input untouched while it fits within `limit + slack`; once it grows past that,
    /// it is cut back to exactly `limit`. The prefix therefore survives several turns unchanged,
    /// which is what lets the provider read its cache instead of rewriting it.
    public static func trim(
        _ history: [AIMessage],
        limit: Int
    ) -> (messages: [AIMessage], trimmedFrom: Int?) {
        guard limit != Int.max, history.count > limit else {
            return (history, nil)
        }
        let allowance = limit + slack(for: limit)
        guard history.count > allowance else {
            return (history, nil)
        }
        return (Array(history.suffix(limit)), history.count)
    }
}
