// MCPRestartPolicy.swift
// ChappieCore
//
// Decides what to do when the ChappieMCP helper dies unexpectedly.
//
// Why a pure value type: the timing rules are the part worth testing; the process handling
// around them (MCPHelperLauncher, app target) just asks this struct "restart or give up?".

import Foundation

public struct MCPRestartPolicy: Sendable, Equatable {

    public enum Decision: Sendable, Equatable {
        case restart(after: TimeInterval)
        case giveUp
    }

    /// Pause before restart attempt N (1-based), growing so a persistent fault doesn't spin.
    /// One entry per allowed restart: the Nth quick failure in a row is the last one tolerated.
    public static let backoff: [TimeInterval] = [1, 2, 4, 8]

    /// A helper that stayed up this long was healthy; its later death starts a fresh series.
    public static let healthyUptime: TimeInterval = 60

    /// Quick failures in a row after which we stop and report instead of looping silently.
    public static let maxQuickFailures = backoff.count + 1

    public private(set) var quickFailures = 0

    public init() {}

    /// Records one unexpected exit and returns what to do next.
    public mutating func recordExit(uptime: TimeInterval) -> Decision {
        if uptime >= Self.healthyUptime { quickFailures = 0 }
        quickFailures += 1
        guard quickFailures < Self.maxQuickFailures else { return .giveUp }
        return .restart(after: Self.backoff[quickFailures - 1])
    }

    /// Fresh budget — used when the user or a tool call explicitly asks for a restart.
    public mutating func reset() { quickFailures = 0 }
}
