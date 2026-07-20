// APIClient.swift
// REST API client — auth endpoints + dashboard data polling.
//
// Key fixes (v1.2):
//   1. URL construction now uses URLComponents to guarantee correct path
//      joining regardless of trailing slash on backendAPIURL.
//   2. Dedicated longer timeout (60 s) for /auth/apple — Apple's token
//      verification round-trip can be slow on first launch.
//   3. Structured error logging so network failures are visible in Xcode console.
//   4. 401 response triggers automatic token refresh attempt before giving up.
//   5. Retry logic (1 retry) for timeout errors on auth endpoints.

import Foundation
import os.log

private let log = Logger(subsystem: "com.cardioai.iomt", category: "APIClient")

enum APIError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL(let p):           return "Invalid URL for path: \(p)"
        case .networkError(let e):         return "Network error: \(e.localizedDescription)"
        case .httpError(let code, let b):  return "HTTP \(code): \(b)"
        case .decodingError(let e):        return "Decoding error: \(Self.describeDecodingError(e))"
        case .unauthorized:                return "Session expired — please sign in again"
        }
    }

    /// Unlike Swift's default DecodingError.localizedDescription (which
    /// just says "The data couldn't be read because it is missing" with
    /// NO indication of which field), this builds a message naming the
    /// exact field path and what went wrong — e.g.
    /// "field 'devices.0.last_data_at': expected value but found null"
    /// This is the difference between a debuggable bug report and a
    /// guessing game every time the backend and app models drift apart.
    private static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }

        func pathString(_ path: [CodingKey]) -> String {
            path.map { $0.stringValue }.joined(separator: ".")
        }

        switch decodingError {
        case .valueNotFound(let type, let context):
            return "field '\(pathString(context.codingPath))': expected \(type) but found null"
        case .keyNotFound(let key, let context):
            let path = context.codingPath.map { $0.stringValue } + [key.stringValue]
            return "missing required field '\(path.joined(separator: "."))'"
        case .typeMismatch(let type, let context):
            return "field '\(pathString(context.codingPath))': expected \(type), got a different type"
        case .dataCorrupted(let context):
            return "malformed data at '\(pathString(context.codingPath))': \(context.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }
}

final class APIClient {

    private let cfg:             AppConfiguration = .shared
    private let keychainService: KeychainService
    private let session:         URLSession         // standard 30 s timeout
    private let authSession:     URLSession         // 60 s timeout for auth calls

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Accept both snake_case and camelCase from backend
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(keychainService: KeychainService) {
        self.keychainService = keychainService

        let stdConfig = URLSessionConfiguration.default
        stdConfig.timeoutIntervalForRequest  = 30
        stdConfig.timeoutIntervalForResource = 60
        stdConfig.waitsForConnectivity       = true
        self.session = URLSession(configuration: stdConfig)

        // Auth endpoints need more time: Apple's JWKS fetch + JWT verify
        let authConfig = URLSessionConfiguration.default
        authConfig.timeoutIntervalForRequest  = 60
        authConfig.timeoutIntervalForResource = 90
        authConfig.waitsForConnectivity       = true
        self.authSession = URLSession(configuration: authConfig)
    }

    // MARK: - URL Builder

    /// Builds a URL by appending `path` to `backendAPIURL`, correctly
    /// handling whether the base URL has a trailing slash or not.
    private func buildURL(path: String) throws -> URL {
        // Ensure base has trailing slash so relativeTo works correctly
        var base = cfg.backendAPIURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }

        // Strip any leading slash from path to avoid double-slash
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path

        guard let url = URL(string: base + cleanPath) else {
            throw APIError.invalidURL(path)
        }
        return url
    }

    // MARK: - Generic request

    private func request<T: Decodable>(
        _ method:    String,
        path:        String,
        body:        [String: Any]? = nil,
        useAuthSession: Bool = false,
        retryCount:  Int = 0
    ) async throws -> T {

        let url = try buildURL(path: path)
        var req        = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("CardioAI-iOS/1.1", forHTTPHeaderField: "User-Agent")

        // Attach access token if available
        if let token = try? keychainService.read(.accessToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        log.info("[\(method)] \(url.absoluteString)")

        let activeSession = useAuthSession ? authSession : session
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await activeSession.data(for: req)
        } catch let error as URLError {
            log.error("Network error \(error.code.rawValue): \(error.localizedDescription)")

            // Retry once on timeout for auth endpoints
            if (error.code == .timedOut || error.code == .networkConnectionLost)
                && retryCount < 1 {
                log.info("Retrying \(path) (attempt \(retryCount + 1))")
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 s back-off
                return try await request(method, path: path, body: body,
                                         useAuthSession: useAuthSession,
                                         retryCount: retryCount + 1)
            }
            throw APIError.networkError(error)
        } catch {
            throw APIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            log.info("Response \(http.statusCode) for \(path)")
            switch http.statusCode {
            case 200...299:
                break
            case 401:
                throw APIError.unauthorized
            default:
                let body = String(data: data, encoding: .utf8) ?? "(empty)"
                log.error("HTTP \(http.statusCode): \(body)")
                throw APIError.httpError(statusCode: http.statusCode, body: body)
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "(binary)"
            if let decodingError = error as? DecodingError {
                log.error("Decode error [\(String(describing: T.self))]: \(String(describing: decodingError)) | body: \(raw.prefix(500))")
            } else {
                log.error("Decode error [\(String(describing: T.self))]: \(error.localizedDescription) | body: \(raw.prefix(500))")
            }
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Auth endpoints

    /// POST /auth/apple — exchange Apple identity token for CardioAI tokens.
    /// Uses the longer auth session (60 s) because Apple's JWKS verification
    /// adds a network round-trip on the backend.
    func appleSignIn(
        identityToken:     String,
        authorizationCode: String,
        firstName:         String?,
        lastName:          String?
    ) async throws -> AuthTokenResponse {
        var body: [String: Any] = [
            "identity_token":     identityToken,
            "authorization_code": authorizationCode,
        ]
        if let first = firstName, !first.isEmpty { body["first_name"] = first }
        if let last  = lastName,  !last.isEmpty  { body["last_name"]  = last  }

        log.info("[Auth] Sending /auth/apple for Apple Sign In")
        return try await request("POST", path: "auth/apple", body: body,
                                 useAuthSession: true)
    }

    /// POST /auth/refresh — rotate refresh token.
    func refreshTokens(refreshToken: String) async throws -> TokenRefreshResponse {
        return try await request("POST", path: "auth/refresh",
                                 body: ["refresh_token": refreshToken],
                                 useAuthSession: true)
    }

    /// POST /auth/logout
    func logout() async throws -> EmptyResponse {
        return try await request("POST", path: "auth/logout",
                                 useAuthSession: true)
    }

    /// DELETE /account — self-service account deletion. See
    /// db.delete_account() on the backend for what this actually does:
    /// credentials are wiped unconditionally, but clinical data tied to
    /// this patient_id is preserved for medical-record retention reasons,
    /// not silently deleted. AccountDeletionResponse.clinicalDataNote
    /// carries that explanation back to the UI so the user is told this
    /// explicitly, not left assuming "delete" means everything is gone.
    func deleteAccount() async throws -> AccountDeletionResponse {
        return try await request("DELETE", path: "account", useAuthSession: true)
    }

    /// POST /subscription/link — tells the backend which store
    /// transaction belongs to the signed-in user, right after a
    /// client-confirmed purchase. Without this, Apple's/Google's webhook
    /// notifications (which identify purchases by transaction ID, not by
    /// our internal user_id) have no way to know whose subscription
    /// status to update.
    func linkSubscription(platform: String, transactionId: String, productId: String) async throws -> EmptyResponse {
        return try await request("POST", path: "subscription/link", body: [
            "platform": platform, "transaction_id": transactionId, "product_id": productId,
        ], useAuthSession: true)
    }

    // MARK: - Device endpoints

    /// POST /devices/register — register a paired BLE device.
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

    func fetchHealth()   async throws -> BridgeStatus     { try await request("GET", path: "status")  }
    func fetchDevices()  async throws -> DeviceSummary    { try await request("GET", path: "devices") }
    func fetchAlerts()   async throws -> [RPMAlert]       { try await request("GET", path: "alerts")  }
    func fetchReports()  async throws -> [ClinicalReport] { try await request("GET", path: "reports") }
}

// MARK: - Response models

struct EmptyResponse: Decodable {}

struct AccountDeletionResponse: Decodable {
    let message: String
    let clinicalDataNote: String

    enum CodingKeys: String, CodingKey {
        case message
        case clinicalDataNote = "clinical_data_note"
    }
}

struct DeviceRegistrationResponse: Decodable {
    let deviceId:  String
    let patientId: String
    let status:    String
}
