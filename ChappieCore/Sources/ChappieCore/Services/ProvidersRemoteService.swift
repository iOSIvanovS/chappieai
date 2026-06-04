// ProvidersRemoteService.swift
// ChappieCore
//
// Downloads and caches the remote providers catalog from GitHub.
//
// DESIGN:
// - Fetches providers.json once per app session (in-memory cache after first fetch).
// - Returns RemoteProviderCatalog — pure Codable, no SwiftData involvement.
// - Caller is responsible for converting RemoteProvider → AIProvider (done in ViewModel layer).
// - Thread-safe: actor isolation guarantees single-writer semantics on the cache.
//
// CACHE POLICY:
// - cachedCatalog is populated on first successful fetch.
// - Subsequent calls within the same session return the cached value immediately.
// - Cache is invalidated only by calling invalidateCache() or on app restart.
// - forceRefresh: true bypasses the cache and re-fetches unconditionally.

import Foundation

// MARK: - ProvidersRemoteService

public actor ProvidersRemoteService {

    // MARK: - Constants

    private let catalogURL = URL(string: "https://raw.githubusercontent.com/iOSIvanovS/chappieai/main/docs/providers.json")!

    // MARK: - Cache

    private var cachedCatalog: RemoteProviderCatalog? = nil

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Returns the remote providers catalog.
    /// Uses in-memory cache — fetches from GitHub only on first call per session (or when forceRefresh is true).
    public func fetchCatalog(forceRefresh: Bool = false) async throws -> RemoteProviderCatalog {
        if !forceRefresh, let cached = cachedCatalog {
            return cached
        }

        let catalog = try await downloadCatalog()
        cachedCatalog = catalog
        return catalog
    }

    /// Clears the in-memory cache, forcing a fresh fetch on the next call.
    public func invalidateCache() {
        cachedCatalog = nil
    }

    // MARK: - Private

    private func downloadCatalog() async throws -> RemoteProviderCatalog {
        let (data, response) = try await URLSession.shared.data(from: catalogURL)

        guard let http = response as? HTTPURLResponse else {
            throw ProvidersRemoteError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw ProvidersRemoteError.httpError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(RemoteProviderCatalog.self, from: data)
        } catch {
            throw ProvidersRemoteError.decodingFailed(error)
        }
    }
}

// MARK: - ProvidersRemoteError

public enum ProvidersRemoteError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case decodingFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response."
        case .httpError(let code):
            return "HTTP error \(code) while fetching providers catalog."
        case .decodingFailed(let error):
            return "Failed to decode providers catalog: \(error.localizedDescription)"
        }
    }
}
