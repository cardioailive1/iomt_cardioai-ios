// APIClient.swift
// REST API client — auth endpoints + dashboard data polling.
// All requests attach Bearer JWT automatically from Keychain.

import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL:                  return "Invalid URL"
        case .networkError(let e):         return "Network error: \(e.localizedDescription)"
        case .httpError(let code, let b):  return "HTTP \(code): \(b)"
        case .decodingError(let e):        return "Decoding error: \(e.localizedDescription)"
        case .unauthorized:                return "Session expired — please sign in again"
        }
    }
}

final class APIClient {

    private let cfg:             AppConfiguration = .shared
    private let keychainService: KeychainService
    private let session:         URLSession
    private let decoder:         JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Generic request

    private func request<T: Decodable>(
        _ method: String,
        path:     String,
        body:     [String: Any]? = nil
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: cfg.backendAPIURL) else {
            throw APIError.invalidURL
        }
        var req        = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // Attach access token if available
        if let token = try? keychainService.read(.accessToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401:       throw APIError.unauthorized
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                throw APIError.httpError(statusCode: http.statusCode, body: body)
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Auth endpoints

    /// POST /auth/apple — exchange Apple identity token for CardioAI tokens
    func appleSignIn(
        identityToken:     String,
        authorizationCode: String,
        firstName:         String?,
        lastName:          String?
    ) async throws -> AuthTokenResponse {
        var body: [String: Any] = [
            "identity_token":      identityToken,
            "authorization_code":  authorizationCode,
        ]
        if let first = firstName { body["first_name"] = first }
        if let last  = lastName  { body["last_name"]  = last  }
        return try await request("POST", path: "auth/apple", body: body)
    }

    /// POST /auth/refresh — rotate refresh token
    func refreshTokens(refreshToken: String) async throws -> TokenRefreshResponse {
        return try await request("POST", path: "auth/refresh",
                                 body: ["refresh_token": refreshToken])
    }

    /// POST /auth/logout
    func logout() async throws -> EmptyResponse {
        return try await request("POST", path: "auth/logout")
    }

    // MARK: - Device endpoints

    /// POST /devices/register — register a paired BLE device
    func registerDevice(
        deviceID:   String,
        deviceType: String,
        patientID:  String,
        deviceName: String
    ) async throws -> DeviceRegistrationResponse {
        return try await request("POST", path: "devices/register", body: [
            "device_id":   deviceID,
            "device_type": deviceType,
            "patient_id":  patientID,
            "device_name": deviceName,
        ])
    }

    // MARK: - Dashboard endpoints

    func fetchHealth()  async throws -> BridgeStatus    { try await request("GET", path: "health")  }
    func fetchDevices() async throws -> DeviceSummary   { try await request("GET", path: "devices") }
    func fetchAlerts()  async throws -> [RPMAlert]      { try await request("GET", path: "alerts")  }
    func fetchReports() async throws -> [ClinicalReport]{ try await request("GET", path: "reports") }
}

// MARK: - Response models

struct EmptyResponse: Decodable {}

struct DeviceRegistrationResponse: Decodable {
    let deviceId:  String
    let patientId: String
    let status:    String
}
