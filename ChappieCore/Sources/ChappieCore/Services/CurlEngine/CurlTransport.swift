// CurlTransport.swift
// ChappieCore
//
// The only place that touches the network. A protocol so engine tests run against a stub.
//
// Decisions:
// - Redirects are NOT followed. The 3xx answer (with Location) goes back to the model, which
//   then decides; this also makes it impossible to be bounced to a host outside the allow-list.
// - No shared cookie storage and no cache: the engine owns cookies per session key.
// - TLS is the system default; no "ignore certificate errors" switch.

import Foundation

public struct CurlRawResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [CurlHeader]
    public var body: Data
    /// Cookies parsed from Set-Cookie (empty for stubs that do not set any).
    public var cookies: [CurlCookie]
    /// True when the body was cut at the transport's size cap.
    public var truncated: Bool

    public init(status: Int, headers: [CurlHeader] = [], body: Data = Data(),
                cookies: [CurlCookie] = [], truncated: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.cookies = cookies
        self.truncated = truncated
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol CurlTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CurlRawResponse
}

// MARK: - URLSession implementation

public struct URLSessionCurlTransport: CurlTransport {

    public let timeout: TimeInterval
    public let maxBodyBytes: Int

    public init(timeout: TimeInterval = 30, maxBodyBytes: Int = 5_000_000) {
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
    }

    public func send(_ request: URLRequest) async throws -> CurlRawResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var req = request
        req.timeoutInterval = timeout
        let (data, response) = try await session.data(for: req, delegate: NoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var headers: [CurlHeader] = []
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            headers.append(CurlHeader(name, text))
            fields[name] = text
        }
        headers.sort { $0.name.lowercased() < $1.name.lowercased() }

        let cookies: [CurlCookie]
        if let url = http.url {
            cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map {
                CurlCookie(name: $0.name, value: $0.value, path: $0.path,
                           expires: $0.expiresDate, secure: $0.isSecure)
            }
        } else {
            cookies = []
        }

        let truncated = data.count > maxBodyBytes
        return CurlRawResponse(
            status: http.statusCode,
            headers: headers,
            body: truncated ? data.prefix(maxBodyBytes) : data,
            cookies: cookies,
            truncated: truncated
        )
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
