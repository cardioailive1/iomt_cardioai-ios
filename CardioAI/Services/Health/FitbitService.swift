// FitbitService.swift
// Fitbit integration via OAuth2 Authorization Code + PKCE flow, followed
// by periodic polling of Fitbit's Web API for heart rate data.
//
// Why this looks different from the BLE and Apple Watch paths
// ─────────────────────────────────────────────────────────────
// Fitbit trackers do NOT expose their data over local BLE to third-party
// apps (their BLE protocol is proprietary and closed) — the only
// supported way to read Fitbit data is through Fitbit's cloud Web API,
// authenticated via OAuth2. This means:
//   - No local BLE scanning/pairing — the user is sent to Fitbit's login
//     page in a secure browser sheet (ASWebAuthenticationSession).
//   - Data arrives via periodic polling (this class fetches roughly once
//     every few minutes, respecting Fitbit's rate limit of 150
//     requests/hour/user), not a continuous real-time stream like BLE
//     notifications or HealthKit's observer queries.
//
// IMPORTANT — SETUP REQUIRED BEFORE THIS WORKS
// ───────────────────────────────────────────────
// You must register a real app at https://dev.fitbit.com/apps/new to get
// a Client ID. Fitbit's OAuth2 implementation supports PKCE for public
// (mobile) clients, so no client secret needs to be embedded in the app —
// only a Client ID. Fill in `clientID` and `redirectURI` below with your
// actual registered values; the placeholders will not work.
//
// ALSO IMPORTANT — Fitbit's minute-level "intraday" heart rate endpoint
// (used below) requires your app to be approved by Fitbit for "Personal"
// or partner-level API access — by default, new apps only get access to
// daily summary data, not minute-by-minute readings. Request intraday
// access at https://dev.fitbit.com/build/reference/web-api/intraday/
// before relying on this in production; until approved, the API call
// below will return a 403.

import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

struct FitbitHeartRateSample {
    let bpm:       Double
    let timestamp: Date
}

@MainActor
final class FitbitService: NSObject, ObservableObject {

    // ── Fill these in from your Fitbit developer app registration ────────
    private let clientID    = "YOUR_FITBIT_CLIENT_ID"
    private let redirectURI = "cardioai://fitbit-callback"
    private let scopes      = "heartrate"

    private let authorizeURL = "https://www.fitbit.com/oauth2/authorize"
    private let tokenURL     = "https://api.fitbit.com/oauth2/token"
    private let apiBaseURL   = "https://api.fitbit.com"

    @Published private(set) var isConnected  = false
    @Published private(set) var lastError:  String?

    private let keychainService: KeychainService
    private var pollingTask: Task<Void, Never>?
    private var pkceVerifier = ""
    private var webAuthSession: ASWebAuthenticationSession?

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
        super.init()
        isConnected = (try? keychainService.read(.fitbitAccessToken)) != nil
    }

    // MARK: - OAuth2 (Authorization Code + PKCE)

    func connect() async {
        guard clientID != "YOUR_FITBIT_CLIENT_ID" else {
            lastError = "Fitbit integration is not configured yet — register an app at dev.fitbit.com and set clientID in FitbitService.swift"
            logger_ios.warning("[Fitbit] \(self.lastError ?? "")")
            return
        }

        pkceVerifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: pkceVerifier)

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url,
              let scheme = URL(string: redirectURI)?.scheme else {
            lastError = "Invalid Fitbit OAuth configuration"
            return
        }

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                    if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: error ?? URLError(.unknown))
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.webAuthSession = session
                session.start()
            }

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                lastError = "Fitbit did not return an authorization code"
                return
            }

            try await exchangeCodeForToken(code: code)
            isConnected = true
            lastError   = nil
            startPolling()
        } catch {
            lastError = "Fitbit sign-in failed: \(error.localizedDescription)"
            logger_ios.warning("[Fitbit] auth failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        stopPolling()
        try? keychainService.delete(.fitbitAccessToken)
        try? keychainService.delete(.fitbitRefreshToken)
        isConnected = false
    }

    private func exchangeCodeForToken(code: String) async throws {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": pkceVerifier,
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(FitbitTokenResponse.self, from: data)
        try keychainService.save(decoded.access_token, for: .fitbitAccessToken)
        try keychainService.save(decoded.refresh_token, for: .fitbitRefreshToken)
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = try? keychainService.read(.fitbitRefreshToken) else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Refresh token itself expired/revoked — user needs to reconnect.
            disconnect()
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(FitbitTokenResponse.self, from: data)
        try keychainService.save(decoded.access_token, for: .fitbitAccessToken)
        try keychainService.save(decoded.refresh_token, for: .fitbitRefreshToken)
    }

    // MARK: - Polling for heart rate

    /// `onSample` is called with the most recent heart rate readings each
    /// time a poll succeeds. Polling interval respects Fitbit's rate limit
    /// (150 requests/hour/user = safely under 1 request per ~30 seconds;
    /// this uses a much more conservative 5-minute interval since RPM
    /// alerting doesn't need second-by-second Fitbit data).
    func startPolling(onSample: ((FitbitHeartRateSample) -> Void)? = nil) {
        stopPolling()
        pollingTask = Task {
            while !Task.isCancelled {
                await self.pollLatestHeartRate(onSample: onSample)
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 minutes
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollLatestHeartRate(onSample: ((FitbitHeartRateSample) -> Void)?) async {
        guard var accessToken = try? keychainService.read(.fitbitAccessToken) else { return }

        // NOTE: requires Fitbit "intraday" API approval — see module docstring.
        let urlString = "\(apiBaseURL)/1/user/-/activities/heart/date/today/1d/1min.json"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            var (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                // Access token expired — refresh once and retry.
                try await refreshAccessToken()
                guard let refreshed = try? keychainService.read(.fitbitAccessToken) else { return }
                accessToken = refreshed
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                (data, response) = try await URLSession.shared.data(for: request)
            }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger_ios.warning("[Fitbit] heart rate poll failed with non-200 response")
                return
            }

            let decoded = try JSONDecoder().decode(FitbitIntradayResponse.self, from: data)
            guard let latest = decoded.activitiesHeartIntraday?.dataset.last else { return }

            let sample = FitbitHeartRateSample(bpm: Double(latest.value), timestamp: Date())
            onSample?(sample)
        } catch {
            logger_ios.warning("[Fitbit] heart rate poll error: \(error.localizedDescription)")
        }
    }

    // MARK: - PKCE helpers

    private static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return Data(hashed).base64URLEncodedString()
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension FitbitService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

// MARK: - Fitbit API response models

private struct FitbitTokenResponse: Decodable {
    let access_token:  String
    let refresh_token: String
    let expires_in:    Int
}

private struct FitbitIntradayResponse: Decodable {
    let activitiesHeartIntraday: FitbitIntradayDataset?

    enum CodingKeys: String, CodingKey {
        case activitiesHeartIntraday = "activities-heart-intraday"
    }
}

private struct FitbitIntradayDataset: Decodable {
    let dataset: [FitbitIntradayPoint]
}

private struct FitbitIntradayPoint: Decodable {
    let time:  String
    let value: Int
}

// MARK: - Base64URL helper (for PKCE)

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
