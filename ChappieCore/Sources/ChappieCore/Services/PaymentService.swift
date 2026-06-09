// PaymentService.swift
// ChappieCore
//
// Fetches available plans from backend and creates Lava.top payment invoices.
// All network calls go through our own backend — never directly to Lava.top.

import Foundation

// MARK: - Models

public struct PlanInfo: Identifiable, Sendable {
    public let id: String          // "starter" | "pro" | "team"
    public let name: String
    public let features: String
    public let prices: [String: Double]  // "RUB" -> 3990.0, "USD" -> 39.0, etc.

    public func price(for currency: String) -> Double? {
        prices[currency]
    }
}

public struct PaymentResult: Sendable {
    public let invoiceId: String
    public let paymentURL: URL
}

// MARK: - PaymentService

public actor PaymentService {

    private let backendURL = "https://api.chappieai.ru"

    public init() {}

    // MARK: - Fetch Plans

    /// Returns available plans with prices. No local cache — caller decides caching strategy.
    public func fetchPlans() async throws -> [PlanInfo] {
        let url = URL(string: "\(backendURL)/payment/products")!
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PaymentError.networkError
        }

        // Backend returns prices as a flat [String: Double] dict
        let raw = try JSONDecoder().decode([RawPlanResponse].self, from: data)
        return raw.map { r in
            PlanInfo(id: r.plan, name: r.name, features: r.features, prices: r.prices)
        }
    }

    // MARK: - Create Invoice

    /// Creates a payment invoice via backend → Lava.top. Returns a URL to open in browser.
    public func createInvoice(plan: String, email: String, currency: String) async throws -> PaymentResult {
        let url = URL(string: "\(backendURL)/payment/create")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body = CreateInvoiceRequest(plan: plan, email: email, currency: currency)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PaymentError.networkError }

        switch http.statusCode {
        case 200:
            let result = try JSONDecoder().decode(CreateInvoiceResponse.self, from: data)
            guard let paymentURL = URL(string: result.payment_url) else {
                throw PaymentError.invalidResponse
            }
            return PaymentResult(invoiceId: result.invoice_id, paymentURL: paymentURL)
        case 400:
            throw PaymentError.invalidRequest
        case 502:
            throw PaymentError.providerError
        default:
            throw PaymentError.networkError
        }
    }

    // MARK: - Private Models

    private struct RawPlanResponse: Codable {
        let plan: String
        let name: String
        let features: String
        let prices: [String: Double]
    }

    private struct CreateInvoiceRequest: Codable {
        let plan: String
        let email: String
        let currency: String
    }

    private struct CreateInvoiceResponse: Codable {
        let invoice_id: String
        let payment_url: String
        let amount: Double?
        let currency: String
    }
}

// MARK: - PaymentError

public enum PaymentError: Error, LocalizedError {
    case networkError
    case invalidRequest
    case invalidResponse
    case providerError

    public var errorDescription: String? {
        switch self {
        case .networkError:    return "Cannot reach payment server"
        case .invalidRequest:  return "Invalid payment request"
        case .invalidResponse: return "Unexpected response from payment server"
        case .providerError:   return "Payment provider error"
        }
    }
}
