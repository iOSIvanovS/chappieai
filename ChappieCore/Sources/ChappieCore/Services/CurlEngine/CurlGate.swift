// CurlGate.swift
// ChappieCore
//
// Deterministic access decision for Curl-Chappie: may this method go to this URL?
// The model never decides what "looks like a login" — only the configured host list does.

import Foundation

public enum CurlAccess: Equatable, Sendable {
    case allowed(host: CurlHost, isLogin: Bool)
    case denied(String)
}

public enum CurlGate {

    public static let readMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]
    public static let writeMethods: Set<String> = ["POST", "PUT", "PATCH", "DELETE"]

    /// True for anything that can change server state.
    public static func isMutating(_ method: String) -> Bool {
        !readMethods.contains(method.uppercased())
    }

    public static func evaluate(method rawMethod: String, url: URL, hosts: [CurlHost]) -> CurlAccess {
        let method = rawMethod.uppercased()
        guard readMethods.contains(method) || writeMethods.contains(method) else {
            return .denied("Unsupported HTTP method '\(rawMethod)'. Allowed: GET, HEAD, OPTIONS, POST, PUT, PATCH, DELETE.")
        }
        guard let origin = CurlOrigin.origin(of: url) else {
            return .denied("URL must be http(s) with a host and without embedded credentials.")
        }
        guard let host = hosts.first(where: { $0.origin == origin }) else {
            return .denied(notListed(origin, hosts))
        }

        let isLogin = method == "POST" && isLoginPath(url, loginPath: host.loginPath)
        if readMethods.contains(method) { return .allowed(host: host, isLogin: false) }

        switch host.permission {
        case .full:
            return .allowed(host: host, isLogin: isLogin)
        case .readOnly:
            return .denied("Host '\(host.name)' (\(origin)) is read-only: only GET, HEAD and OPTIONS are allowed. The user can raise the permission in thread settings.")
        case .readAndLogin:
            if isLogin { return .allowed(host: host, isLogin: true) }
            let hint = host.loginPath.isEmpty
                ? "no login path is configured for it"
                : "the only POST allowed is the login path \(host.loginPath)"
            return .denied("Host '\(host.name)' (\(origin)) allows reading and login only; \(hint).")
        }
    }

    /// Exact match on the normalized path. Dot segments are refused so
    /// "/api/login/../admin" can never pass as the login path.
    static func isLoginPath(_ url: URL, loginPath: String) -> Bool {
        guard !loginPath.isEmpty,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let raw = comps.percentEncodedPath
        let hasDotSegment = raw.split(separator: "/", omittingEmptySubsequences: false).contains { segment in
            let decoded = String(segment).removingPercentEncoding?.lowercased() ?? segment.lowercased()
            return decoded == "." || decoded == ".."
        }
        if hasDotSegment { return false }
        return CurlOrigin.normalizePath(raw) == loginPath
    }

    private static func notListed(_ origin: String, _ hosts: [CurlHost]) -> String {
        if hosts.isEmpty {
            return "Host \(origin) is not allowed: this thread has no Curl-Chappie hosts. Ask the user to add one in thread settings."
        }
        let list = hosts.map { "\($0.name) = \($0.origin) [\($0.permission.rawValue)]" }.joined(separator: "; ")
        return "Host \(origin) is not in this thread's Curl-Chappie host list. Allowed: \(list). Ask the user to add the host if it is needed."
    }
}
