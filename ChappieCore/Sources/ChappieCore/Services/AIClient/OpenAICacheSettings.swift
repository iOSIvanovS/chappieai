// OpenAICacheSettings.swift
// ChappieCore
//
// Where the cache breakpoint goes on the OpenAI-compatible route (AITunnel and alike), and whether
// the request carries a session id.
//
// RESULT (2026-11-24, AITunnel): `explicit` fixed it — read grows by the previous step's created, created
// fell from 4-14k to ~250-550 tokens per step. `session_id` changed nothing, so it stays off by default.
// The switches remain as a fallback if a gateway rejects block-level cache_control.
//
// WHY SWITCHABLE: measured on AITunnel, the cache read stayed pinned at the same number while the
// written part grew on every step. Two causes were suspected and each was cheap to test alone:
//   1. A top-level cache_control puts the breakpoint after the LAST block — behind the live screen
//      frame, which vanishes on the next step, so the entry written there is never read back.
//   2. Without a session id the gateway may send consecutive requests to different upstream
//      providers, and a cache lives at one provider only.
// The values are read per request from UserDefaults, so an experiment needs a relaunch, not a rebuild:
//   defaults write tmf.Chappie openaiCachePlacement explicit   (or topLevel)
//   defaults write tmf.Chappie openaiCacheSession -bool true

import Foundation

enum OpenAICachePlacement: String, Sendable {
    /// One top-level `cache_control`: the gateway picks the last cacheable block.
    case topLevel
    /// Explicit breakpoints on blocks: the system prompt and the last message before the screen frame.
    case explicit
}

struct OpenAICacheSettings: Equatable, Sendable {
    var placement: OpenAICachePlacement
    var sendSessionID: Bool

    static let placementKey = "openaiCachePlacement"
    static let sessionKey = "openaiCacheSession"

    /// One id for the whole process: enough to pin the experiment to one upstream provider.
    static let processSessionID = UUID().uuidString.lowercased()

    static var current: OpenAICacheSettings {
        resolve(from: .standard)
    }

    /// Defaults are the measured winner on AITunnel (claude-sonnet-5.5): explicit breakpoints keep
    /// `read` growing with the prefix, a top-level one left `read` pinned. A session id changed nothing.
    static func resolve(from defaults: UserDefaults) -> OpenAICacheSettings {
        let placement = defaults.string(forKey: placementKey).flatMap(OpenAICachePlacement.init(rawValue:)) ?? .explicit
        return OpenAICacheSettings(placement: placement, sendSessionID: defaults.bool(forKey: sessionKey))
    }

    var summary: String {
        "placement=\(placement.rawValue) session=\(sendSessionID ? "on" : "off")"
    }
}

enum OpenAICacheBreakpoints {

    /// Puts the breakpoint on the last block of the last message that is not the screen frame.
    ///
    /// Everything after it — the frame — stays outside the cached prefix. A message that cannot carry
    /// a block (no content, or a picture-only turn) is skipped: the breakpoint then lands one message
    /// earlier, which is a shorter prefix but never a wrong one.
    static func marking(_ history: [AIMessage]) -> [AIMessage] {
        guard let index = history.lastIndex(where: { $0.role != ScreenFrame.role && canCarryBreakpoint($0) }) else {
            return history
        }
        var result = history
        var message = result[index]
        switch message.content {
        case .text(let text):
            message.content = .blocks([AIContentBlock(text: text, cacheControl: .oneHour)])
        case .blocks(let blocks):
            var marked = blocks
            let last = marked[marked.count - 1]
            marked[marked.count - 1] = AIContentBlock(text: last.text, cacheControl: .oneHour)
            message.content = .blocks(marked)
        default:
            return history
        }
        result[index] = message
        return result
    }

    private static func canCarryBreakpoint(_ message: AIMessage) -> Bool {
        switch message.content {
        case .text(let text): return !text.isEmpty
        case .blocks(let blocks): return !blocks.isEmpty
        case .multimodal, .none: return false
        }
    }
}
