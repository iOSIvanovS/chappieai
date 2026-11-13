// AIClient+Balance.swift — separate balance request for providers without usage.balance
import Foundation

extension AIClient {

    /// Balance from the response when present, otherwise from the provider's balance endpoint.
    func resolvedBalance(_ fromResponse: Double?) async -> Double? {
        if let fromResponse { return fromResponse }
        return await fetchBalance()
    }

    /// Fetches the account balance after a response. Never throws: a failed balance request
    /// must not break the chat turn, the UI simply keeps the previous value.
    func fetchBalance() async -> Double? {
        guard let source = balanceSource else { return nil }
        var request = URLRequest(url: source.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        applyAuth(to: &request)
        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return source.endpoint.parse(data)
    }
}
