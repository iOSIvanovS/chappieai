// CurlHeaderNoise.swift
// ChappieCore
//
// Folds routine response headers out of the text shown to the model. A deny-list (not an
// allow-list) on purpose: an unknown custom header such as x-debug-message or a rate-limit
// counter is often exactly what a backend debug session needs, so it stays visible.

import Foundation

enum CurlHeaderNoise {

    private static let exact: Set<String> = [
        "date", "server", "connection", "keep-alive", "vary", "cache-control", "expires", "pragma",
        "age", "transfer-encoding", "content-encoding", "accept-ranges", "strict-transport-security",
        "x-content-type-options", "x-frame-options", "x-xss-protection", "referrer-policy",
        "content-security-policy", "permissions-policy", "alt-svc", "via", "x-powered-by"
    ]

    static func isNoise(_ name: String) -> Bool {
        let lower = name.lowercased()
        return exact.contains(lower) || lower.hasPrefix("access-control-")
    }

    static func split(_ headers: [CurlHeader]) -> (shown: [CurlHeader], hidden: Int) {
        let shown = headers.filter { !isNoise($0.name) }
        return (shown, headers.count - shown.count)
    }
}
