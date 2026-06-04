// ProvidersRemoteService.swift
// ChappieCore
//
// Downloads and caches the remote providers catalog from GitHub.

import Foundation

// MARK: - ProvidersRemoteService

public actor ProvidersRemoteService {

    private let catalogURL = URL(string: "https://raw.githubusercontent.com/iOSIvanovS/chappieai/main/docs/providers.json")!
    private var cachedCatalog: RemoteProviderCatalog? = nil

    public init() {}

    public func fetchCatalog(forceRefresh: Bool = false) async throws -> RemoteProviderCatalog {
        if !forceRefresh, let cached = cachedCatalog {
            return cached
        }
        let catalog = try await downloadCatalog()
        cachedCatalog = catalog
        // Log requiresApiKey for each provider to verify correct parsing
        for provider in catalog.providers {
            print("[ProvidersRemoteService] Provider '\(provider.id)' requiresApiKey=\(provider.requiresApiKey)")
        }
        return catalog
    }

    public func findProvider(byCatalogId catalogId: String) -> RemoteProvider? {
        cachedCatalog?.providers.first { $0.id == catalogId }
    }

    public func invalidateCache() {
        cachedCatalog = nil
    }

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
