// AIClient.swift — configuration, init, protocol conformance entry points
import Foundation

// MARK: - StallError

/// Thrown when no tokens arrive within stallTimeout seconds.
/// Distinct from CancellationError (user cancel) and URLError (network failure).
public struct StallError: Error, Sendable {
    public let stallSeconds: TimeInterval
    public let partialText: String

    public init(stallSeconds: TimeInterval, partialText: String) {
        self.stallSeconds = stallSeconds
        self.partialText = partialText
    }
}

// MARK: - AIClient

/// OpenAI-compatible streaming AI client.
/// Use AIClientFactory.make() to get the right client for a given provider+model.
public struct AIClient: Sendable, AIClientProtocol {

    // MARK: - Configuration

    let endpointURL: URL
    let baseURL: URL
    let apiKey: String
    let modelName: String
    let authScheme: AuthScheme
    let urlSession: URLSession

    /// True only for AITunnel — all other providers reject cache_control with HTTP 400.
    let supportsCaching: Bool

    // MARK: - Init (from chat endpoint)

    /// Use when you have the full chat endpoint URL.
    /// baseURL is derived by stripping the path.
    public init(endpoint: String, apiKey: String, modelName: String, authScheme: AuthScheme = .bearer, supportsCaching: Bool = false) {
        self.endpointURL = URL(string: endpoint) ?? URL(string: "https://api.openai.com/v1/chat/completions")!
        self.apiKey = apiKey
        self.modelName = modelName
        self.authScheme = authScheme
        self.supportsCaching = supportsCaching

        if let url = URL(string: endpoint), let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            self.baseURL = URL(string: "\(scheme)://\(host)\(port)") ?? url
        } else {
            self.baseURL = self.endpointURL
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Init (from base URL)

    /// Use for discovery/validation when you know the provider's base URL.
    /// endpointURL = baseURL + /v1/chat/completions.
    public init(baseURL: String, apiKey: String, modelName: String, authScheme: AuthScheme = .bearer, supportsCaching: Bool = false) {
        let base = URL(string: baseURL) ?? URL(string: "https://api.openai.com")!
        self.baseURL = base
        self.endpointURL = base.appendingPathComponent("v1/chat/completions")
        self.apiKey = apiKey
        self.modelName = modelName
        self.authScheme = authScheme
        self.supportsCaching = supportsCaching

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }
}
