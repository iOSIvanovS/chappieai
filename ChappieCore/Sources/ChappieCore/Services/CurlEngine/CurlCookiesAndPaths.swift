// CurlCookiesAndPaths.swift
// ChappieCore
//
// Small pure helpers: a per-session cookie jar and JSON value extraction.
// The jar is per session key (origin + identity), so cookies of one host never reach another.

import Foundation

public struct CurlCookie: Sendable, Equatable {
    public var name: String
    public var value: String
    public var path: String
    public var expires: Date?
    public var secure: Bool

    public init(name: String, value: String, path: String = "/", expires: Date? = nil, secure: Bool = false) {
        self.name = name
        self.value = value
        self.path = path.isEmpty ? "/" : path
        self.expires = expires
        self.secure = secure
    }
}

public enum CurlCookieJar {

    /// Applies incoming cookies. A cookie that is already expired deletes the stored one
    /// (that is how servers log a session out).
    public static func merge(_ jar: [CurlCookie], _ incoming: [CurlCookie], now: Date) -> [CurlCookie] {
        var result = jar
        for cookie in incoming {
            result.removeAll { $0.name == cookie.name && $0.path == cookie.path }
            if let expires = cookie.expires, expires <= now { continue }
            result.append(cookie)
        }
        return result
    }

    /// Value of the Cookie header for a request path, or nil when nothing applies.
    public static func header(_ jar: [CurlCookie], path: String, isHTTPS: Bool, now: Date) -> String? {
        let applicable = jar.filter { cookie in
            if let expires = cookie.expires, expires <= now { return false }
            if cookie.secure && !isHTTPS { return false }
            return path.hasPrefix(cookie.path)
        }
        guard !applicable.isEmpty else { return nil }
        return applicable
            .sorted { $0.path.count > $1.path.count }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

public enum CurlJSONPath {

    private enum Token { case key(String), index(Int) }

    /// Returns the value as text: strings as-is, numbers and booleans as written, containers as
    /// compact JSON, null/missing as nil.
    public static func extract(_ path: String, from data: Data) -> String? {
        guard let tokens = parse(path),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }

        var current: Any = root
        for token in tokens {
            switch token {
            case .key(let key):
                guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? [Any], index >= 0, index < array.count else { return nil }
                current = array[index]
            }
        }
        return stringify(current)
    }

    private static func parse(_ raw: String) -> [Token]? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("$") { path.removeFirst() }
        if path.hasPrefix(".") { path.removeFirst() }
        guard !path.isEmpty else { return nil }

        var tokens: [Token] = []
        var key = ""
        var lastWasIndex = false
        var i = path.startIndex
        while i < path.endIndex {
            let ch = path[i]
            if ch == "." {
                if !key.isEmpty {
                    tokens.append(.key(key)); key = ""
                } else if !lastWasIndex {
                    return nil   // "a..b" or leading dot
                }
                lastWasIndex = false
                i = path.index(after: i)
            } else if ch == "[" {
                if !key.isEmpty { tokens.append(.key(key)); key = "" }
                guard let close = path[i...].firstIndex(of: "]"),
                      let index = Int(path[path.index(after: i)..<close]) else { return nil }
                tokens.append(.index(index))
                lastWasIndex = true
                i = path.index(after: close)
            } else {
                key.append(ch)
                lastWasIndex = false
                i = path.index(after: i)
            }
        }
        if !key.isEmpty { tokens.append(.key(key)) }
        return tokens.isEmpty ? nil : tokens
    }

    private static func stringify(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
