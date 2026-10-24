// RetryStatus+Label.swift
// Chappie
//
// Turns the core's retry progress into the short localized line shown in the agent action bar.

import Foundation
import ChappieCore

extension RetryStatus {

    var localizedLabel: String {
        let head: String
        switch reason {
        case .http(let code):
            head = String(format: String(localized: "retry.reason.http"), code)
        case .rateLimited:
            head = String(localized: "retry.reason.rate_limited")
        case .network:
            head = String(localized: "retry.reason.network")
        case .timeout:
            head = String(localized: "retry.reason.timeout")
        case .stall:
            head = String(localized: "retry.reason.stall")
        }

        if secondsRemaining > 0 {
            return String(format: String(localized: "retry.progress.wait"), head, attempt, maxAttempts, secondsRemaining)
        }
        return String(format: String(localized: "retry.progress.now"), head, attempt, maxAttempts)
    }
}
