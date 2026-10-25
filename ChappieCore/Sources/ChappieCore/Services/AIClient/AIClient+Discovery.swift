// AIClient+Discovery.swift — fetchAvailableModels, validateProvider, validateConnection
import Foundation

extension AIClient {

    // MARK: - fetchAvailableModels

    public func fetchAvailableModels() async -> [String] {
        let modelsURL = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        applyAuth(to: &request)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }

            struct ModelsResponse: Decodable {
                struct ModelObject: Decodable { let id: String }
                let data: [ModelObject]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map { $0.id }.sorted()
        } catch {
            print("[AIClient] fetchAvailableModels failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - validateProvider

    public func validateProvider() async throws {
        let modelsURL = baseURL.appendingPathComponent("v1/models")
        var req = URLRequest(url: modelsURL)
        req.httpMethod = "GET"
        applyAuth(to: &req)
        req.timeoutInterval = 15

        do {
            let (_, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 401 || http.statusCode == 403 {
                throw ChappieError.networkError("HTTP \(http.statusCode): Invalid API key or unauthorized.")
            }
            print("[AIClient] Provider validated (HTTP \(http.statusCode)): \(baseURL.host ?? "")")
        } catch let error as ChappieError {
            throw error
        } catch {
            throw ChappieError.networkError("Cannot reach provider: \(error.localizedDescription)")
        }
    }

    // MARK: - validateConnection

    public func validateConnection() async throws {
        let body = AITunnelRequest(
            model: modelName,
            messages: [AIMessage(role: "user", content: "hi")],
            tools: nil,
            stream: false,
            cacheControl: nil
        )
        let request = try buildURLRequest(body: body)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)
        print("[AIClient] Connection validated: \(endpointURL.host ?? "") / \(modelName)")
    }
}
