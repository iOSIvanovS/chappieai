import Foundation

// MARK: - Network DTOs

extension LicenseService {

    struct TrialResponse: Codable {
        let key: String
        let plan: String
        let expires_at: String?
        let is_active: Bool

        var expiresAt: String? { expires_at }
        var isActive: Bool { is_active }
    }

    struct ValidateRequest: Codable {
        let license_key: String
        let hardware_id: String
    }

    struct ValidateResponse: Codable {
        let is_active: Bool
        let plan: String?
        let expires_at: String?

        var isActive: Bool { is_active }
        var expiresAt: String? { expires_at }
    }

    struct ActivateRequest: Codable {
        let license_key: String
        let hardware_id: String
    }

    struct ActivateResponse: Codable {
        let key: String
        let plan: String
        let expires_at: String?
        let hardware_id: String?

        var expiresAt: String? { expires_at }
    }
}

// MARK: - Network Calls

extension LicenseService {

    func registerTrialOnline(hardwareId: String) async throws -> TrialResponse {
        let url = URL(string: "\(backendURL)/license/trial?hardware_id=\(hardwareId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LicenseError.networkError
        }
        return try JSONDecoder().decode(TrialResponse.self, from: data)
    }

    func validateOnline(key: String, hardwareId: String) async throws -> ValidateResponse {
        let url = URL(string: "\(backendURL)/license/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ValidateRequest(license_key: key, hardware_id: hardwareId))
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseError.networkError }

        if http.statusCode == 403 || http.statusCode == 404 {
            throw LicenseError.licenseInvalid
        }
        guard http.statusCode == 200 else { throw LicenseError.networkError }
        return try JSONDecoder().decode(ValidateResponse.self, from: data)
    }

    func activateOnline(key: String, hardwareId: String) async throws -> ActivateResponse {
        let url = URL(string: "\(backendURL)/license/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ActivateRequest(license_key: key, hardware_id: hardwareId))
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseError.networkError }

        switch http.statusCode {
        case 200: return try JSONDecoder().decode(ActivateResponse.self, from: data)
        case 403: throw LicenseError.licenseInvalid
        case 409: throw LicenseError.deviceLimitReached
        default:  throw LicenseError.networkError
        }
    }
}
