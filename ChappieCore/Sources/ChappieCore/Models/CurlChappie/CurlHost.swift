// CurlHost.swift
// ChappieCore
//
// Thread-scoped allow-list entry for Curl-Chappie (the HTTP request tool).
// A request is only ever sent to an origin that is listed here; the permission
// decides which methods are allowed on it.
//
// CODABLE COMPATIBILITY CONTRACT: same as ThreadModels — never rename or remove stored
// keys, always default new ones.

import Foundation

// MARK: - CurlHostPermission

/// What the agent may do on a host. Deterministic — the model never decides "this looks like a login".
public enum CurlHostPermission: String, Codable, Sendable, CaseIterable {
    /// GET and HEAD only.
    case readOnly
    /// GET, HEAD and POST to the single configured login path (session acquisition is a POST).
    case readAndLogin
    /// Any method. Non-GET requests still go through user confirmation in confirm mode.
    case full
}

// MARK: - CurlHost

public struct CurlHost: Codable, Sendable, Identifiable, Hashable {

    public let id: UUID
    /// Human label shown in the settings table, e.g. "Dev".
    public var name: String
    /// Normalized origin (scheme://host[:port]) — see `CurlOrigin.normalize`.
    public var origin: String
    public var permission: CurlHostPermission
    /// Path allowed for POST under `.readAndLogin`, e.g. "/api/login/token". Empty = none.
    public var loginPath: String

    public init(
        id: UUID = UUID(),
        name: String,
        origin: String,
        permission: CurlHostPermission = .readOnly,
        loginPath: String = ""
    ) {
        self.id = id
        self.name = name
        self.origin = CurlOrigin.normalize(origin) ?? origin
        self.permission = permission
        self.loginPath = CurlOrigin.normalizePath(loginPath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, origin, permission, loginPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        // Unknown future permission falls back to the safest level.
        permission = (try? c.decodeIfPresent(CurlHostPermission.self, forKey: .permission)) ?? .readOnly
        loginPath = try c.decodeIfPresent(String.self, forKey: .loginPath) ?? ""
    }
}

// MARK: - CurlOrigin

/// Pure helpers for origins and paths. One place defines what "the same host" means,
/// so secret binding, host matching and session keys can never disagree.
public enum CurlOrigin {

    /// "HTTPS://Dev.Adept.ru:443/api?x=1" → "https://dev.adept.ru".
    /// Returns nil for non-http(s) schemes, missing hosts, or URLs carrying credentials
    /// (user:pass@host would let a secret leak into the URL).
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              comps.user == nil, comps.password == nil,
              let host = comps.host?.lowercased(), !host.isEmpty
        else { return nil }

        let defaultPort = scheme == "https" ? 443 : 80
        let hostPart = host.contains(":") ? "[\(host)]" : host
        if let port = comps.port, port != defaultPort {
            return "\(scheme)://\(hostPart):\(port)"
        }
        return "\(scheme)://\(hostPart)"
    }

    /// Origin of a full URL, or nil if it is not an acceptable http(s) URL.
    public static func origin(of url: URL) -> String? {
        normalize(url.absoluteString)
    }

    /// Login path normalization: leading slash, no query/fragment, no trailing slash (except root).
    /// Empty stays empty.
    public static func normalizePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<cut])
        }
        guard !path.isEmpty else { return "" }
        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
