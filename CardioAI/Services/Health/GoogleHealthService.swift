// GoogleHealthService.swift
// Reads Fitbit (and Pixel Watch) heart rate data via the Google Health API
// — the platform that REPLACED the legacy Fitbit Web API.
//
// WHY THIS FILE ISN'T CALLED "FitbitService.swift" ANYMORE
// ────────────────────────────────────────────────────────────
// As of 2026, Google (which owns Fitbit) is retiring the old Fitbit Web
// API entirely:
//   - New developer registration for the legacy Fitbit dev portal
//     (dev.fitbit.com) is closed. This is why registering a new Fitbit
//     app there no longer works.
//   - The replacement is the Google Health API (health.googleapis.com/v4),
//     which is live now and uses standard Google Cloud / Google OAuth 2.0
//     infrastructure instead of Fitbit's own developer console.
//   - The legacy Fitbit Web API is fully shut off in September 2026 —
//     after that, apps still using it stop syncing entirely.
// So this integration now targets the Google Health API directly rather
// than a deprecated platform that would stop working within months.
//
// SETUP REQUIRED BEFORE THIS WORKS
// ───────────────────────────────────
// 1. Create a project in Google Cloud Console (console.cloud.google.com).
// 2. Enable the "Google Health API" for that project.
// 3. Create an OAuth 2.0 Client ID of type "iOS" (this is a public client
//    — no client secret needed, matching the PKCE flow used below). Set
//    the bundle ID to match this app's bundle identifier.
// 4. Under "Data Access", add the scope:
//        https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly
// 5. Under "Audience", the app starts in "Testing" status — add up to 100
//    Google account emails as "Test users" to pull real data immediately
//    WITHOUT needing Google's formal review. This is the practical path
//    for development/TestFlight testing right now.
// 6. Fill in `clientID` and `redirectURI` below with your real values.
//
// IMPORTANT — GOING TO PRODUCTION (real patients, not test users)
// ───────────────────────────────────────────────────────────────
// Google classifies ALL Google Health API scopes as "Restricted." Before
// you can remove the Testing/test-user restriction and let arbitrary
// patients connect their own Fitbit accounts, Google requires a formal
// privacy & security review (a CASA assessment via an authorized lab).
// This is a real compliance process — budget time and, likely, cost for
// it well before a general release. It is a materially bigger lift than
// the old Fitbit dev portal, which had no such review for basic access.
//
// A NOTE ON API STABILITY
// ─────────────────────────
// The Google Health API is new (general availability mid-2026) and its
// own documentation describes schemas/scopes as still evolving. The
// endpoints, OAuth flow, and scope name below are taken directly from
// Google's current published documentation, but the exact JSON shape of
// a heart rate data point response is parsed defensively here (tolerant
// of missing/renamed fields) since Google's docs note the response shape
// may still change before the API fully stabilizes.

import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

struct GoogleHealthReading {
    let bpm:       Double
    let timestamp: Date
}

@MainActor
final class GoogleHealthService: NSObject, ObservableObject {

    // ── Fill these in from your Google Cloud Console OAuth client ────────
    private let clientID    = "875586651219-mluk6di2f06flcj0mrl92fv8r644050b.apps.googleusercontent.com"
    private let redirectURI = "com.googleusercontent.apps.875586651219-mluk6di2f06flcj0mrl92fv8r644050b:/oauth2redirect"
    private let scope       = "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly"

    private let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL     = "https://oauth2.googleapis.com/token"
    private let apiBaseURL   = "https://health.googleapis.com/v4"

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

    // MARK: - OAuth2 (Google's standard Authorization Code + PKCE flow)

    func connect() async {
        guard clientID != "YOUR_GOOGLE_OAUTH_CLIENT_ID" else {
            lastError = "Google Health integration is not configured yet — create an OAuth client in Google Cloud Console and set clientID in GoogleHealthService.swift"
            logger_ios.warning("[GoogleHealth] \(self.lastError ?? "")")
            return
        }

        pkceVerifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: pkceVerifier)

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Deliberately NOT setting include_granted_scopes=true — if a
            // user previously consented to legacy Google Fit `fitness.*`
            // scopes under the same OAuth client, mixing those into this
            // token causes the Health API's data endpoints to 403 even
            // though the token looks valid. This is a known sharp edge
            // with this API as of its 2026 GA.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url,
              let scheme = URL(string: redirectURI)?.scheme else {
            lastError = "Invalid Google OAuth configuration"
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
                lastError = "Google did not return an authorization code"
                return
            }

            try await exchangeCodeForToken(code: code)
            isConnected = true
            lastError   = nil
            await logIdentityForDebugging()
            startPolling()
        } catch {
            lastError = "Google sign-in failed: \(error.localizedDescription)"
            logger_ios.warning("[GoogleHealth] auth failed: \(error.localizedDescription)")
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

        let decoded = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        try keychainService.save(decoded.access_token, for: .fitbitAccessToken)
        if let refreshToken = decoded.refresh_token {
            try keychainService.save(refreshToken, for: .fitbitRefreshToken)
        }
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
        let decoded = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        try keychainService.save(decoded.access_token, for: .fitbitAccessToken)
        // Google typically does NOT return a new refresh_token on refresh —
        // only keep the existing one unless a new one is actually issued.
        if let refreshToken = decoded.refresh_token {
            try keychainService.save(refreshToken, for: .fitbitRefreshToken)
        }
    }

    /// Google Health API tokens carry no user identifier by default — you
    /// must call getIdentity() once after connecting to obtain both the
    /// legacy Fitbit user ID and the new Google health user ID. Logged
    /// for now; wire into your own user-linking logic if you need to
    /// reconcile against a legacy Fitbit-era user record.
    private func logIdentityForDebugging() async {
        guard let token = try? keychainService.read(.fitbitAccessToken) else { return }
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/users/me/identity")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (data, _) = try? await URLSession.shared.data(for: request) {
            logger_ios.info("[GoogleHealth] identity response: \(String(data: data, encoding: .utf8) ?? "?")")
        }
    }

    // MARK: - Polling for heart rate

    /// `onSample` is called with the most recent heart rate readings each
    /// time a poll succeeds. 5-minute interval is conservative — the
    /// Google Health API's default list endpoint returns intraday data
    /// automatically (unlike the old Fitbit API, which needed a special
    /// "intraday" access grant), so this is purely to avoid unnecessary
    /// polling frequency, not a rate-limit workaround.
    func startPolling(onSample: ((GoogleHealthReading) -> Void)? = nil) {
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

    private func pollLatestHeartRate(onSample: ((GoogleHealthReading) -> Void)?) async {
        guard var accessToken = try? keychainService.read(.fitbitAccessToken) else { return }

        // Google Health API: GET /v4/users/me/dataTypes/{slug}/dataPoints.
        // Slugs are kebab-case per Google's published data-type table
        // (heart-rate, blood-glucose, active-energy-burned, …) — an earlier
        // "camelCase" assumption (heartRate) was wrong and 404s. JSON *fields*
        // inside a point are still camelCase (heartRate.beatsPerMinute).
        guard var url = URL(string: "\(apiBaseURL)/users/me/dataTypes/heart-rate/dataPoints") else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page_size", value: "10")]
        url = components.url!

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            var (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                try await refreshAccessToken()
                guard let refreshed = try? keychainService.read(.fitbitAccessToken) else { return }
                accessToken = refreshed
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                (data, response) = try await URLSession.shared.data(for: request)
            }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "?"
                logger_ios.warning("[GoogleHealth] heart rate poll failed (status not logged, see body): \(body.prefix(300))")
                return
            }

            // Defensive parsing: the API is new enough that the exact
            // wrapper key/field names are worth tolerating drift on.
            // Tries the documented shape first, falls back to scanning
            // for any "beatsPerMinute" value in the raw JSON if the
            // wrapper shape doesn't match what's expected.
            if let reading = Self.parseLatestHeartRate(from: data) {
                onSample?(reading)
            } else {
                logger_ios.warning("[GoogleHealth] could not find a heart rate value in response — API shape may have changed")
            }
        } catch {
            logger_ios.warning("[GoogleHealth] heart rate poll error: \(error.localizedDescription)")
        }
    }

    private static func parseLatestHeartRate(from data: Data) -> GoogleHealthReading? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Documented shape (per Google's example data point):
        // { "dataPoints": [ { "heartRate": {"beatsPerMinute": 72},
        //                     "dataSource": {...},
        //                     "sampleTime" or similar timestamp field } ] }
        if let points = json["dataPoints"] as? [[String: Any]], let latest = points.last {
            let bpm = firstNumeric(in: latest, keys: ["beatsPerMinute", "bpm", "value"])
            if bpm > 0 { return GoogleHealthReading(bpm: bpm, timestamp: Date()) }
        }
        return nil
    }

    // MARK: - Fitness + aux vitals (Fitbit source)
    //
    // dataType slugs are kebab-case per Google's published Health API spec
    // (developers.google.com/health/migration/api-specifications): steps,
    // active-energy-burned, exercise, oxygen-saturation. JSON value fields:
    // steps→{steps:{count}}, active-energy-burned→{kcal}, oxygen-saturation→
    // %, exercise→documented shape (see parseWorkouts). Parsing stays tolerant
    // (depth-first numeric scan). Note: Google Health has NO blood-pressure
    // dataType (Fitbit devices don't measure BP), so BP is never fetched here.
    // ponytail: verify against a live Fitbit account — Google flags response
    // shapes pre-stabilization, and some types may need a broader OAuth scope.

    /// Today's step count from Google Health, or 0 if unavailable.
    func fetchTodaySteps() async -> Double {
        let points = await fetchDataPoints(dataType: "steps")
        return points.reduce(0) { $0 + Self.firstNumeric(in: $1, keys: ["countSum", "count", "steps", "value"]) }
    }

    /// Today's active energy (kcal) from Google Health, or 0 if unavailable.
    func fetchTodayActiveEnergy() async -> Double {
        let points = await fetchDataPoints(dataType: "active-energy-burned")
        return points.reduce(0) { $0 + Self.firstNumeric(in: $1, keys: ["kcal", "kilocalories", "calories", "value"]) }
    }

    /// Latest SpO2 reading (0–100), or nil if unavailable. Handles both
    /// percentage (97) and fraction (0.97) representations.
    func fetchLatestSpO2() async -> Double? {
        let points = await fetchDataPoints(dataType: "oxygen-saturation")
        guard let latest = points.last else { return nil }
        let v = Self.firstNumeric(in: latest, keys: ["percentage", "oxygenSaturation", "spo2", "saturation", "value"])
        guard v > 0 else { return nil }
        return v <= 1 ? v * 100 : v
    }

    /// Best-effort trend: returns today's total keyed to today rather than
    /// fabricating a 7-day shape, since the API's per-day time-window params
    /// aren't verified. ponytail: wire real daily windows once confirmed.
    func fetchStepsTrend(days: Int = 7) async -> [(date: Date, steps: Double)] {
        let today = await fetchTodaySteps()
        return [(Calendar.current.startOfDay(for: Date()), today)]
    }

    /// Recent Fitbit workouts via the Google Health `exercise` dataType, most
    /// recent first. Fields per Google's published schema (interval.startTime/
    /// endTime, exerciseType, displayName, activeDuration, metricsSummary.
    /// caloriesKcal).
    func fetchRecentWorkouts(limit: Int = 5) async -> [WorkoutSummary] {
        let points = await fetchDataPoints(dataType: "exercise", pageSize: limit)
        return Self.parseWorkouts(from: points, limit: limit)
    }

    /// Shared GET for `dataTypes/{slug}/dataPoints` — handles auth, one 401
    /// refresh-and-retry, and returns the `dataPoints` array (empty on failure).
    private func fetchDataPoints(dataType: String, pageSize: Int = 10) async -> [[String: Any]] {
        guard var accessToken = try? keychainService.read(.fitbitAccessToken) else { return [] }
        guard let base = URL(string: "\(apiBaseURL)/users/me/dataTypes/\(dataType)/dataPoints"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = [URLQueryItem(name: "page_size", value: "\(max(pageSize, 1))")]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            var (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                try await refreshAccessToken()
                guard let refreshed = try? keychainService.read(.fitbitAccessToken) else { return [] }
                accessToken = refreshed
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "?"
                logger_ios.warning("[GoogleHealth] \(dataType) fetch failed: \(body.prefix(200))")
                return []
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let points = json["dataPoints"] as? [[String: Any]] else { return [] }
            return points
        } catch {
            logger_ios.warning("[GoogleHealth] \(dataType) fetch error: \(error.localizedDescription)")
            return []
        }
    }

    private static func parseWorkouts(from points: [[String: Any]], limit: Int) -> [WorkoutSummary] {
        let workouts: [WorkoutSummary] = points.compactMap { point in
            // Documented shape: point.exercise.{ interval.{startTime,endTime},
            // exerciseType, displayName, activeDuration ("1800s"),
            // metricsSummary.caloriesKcal }.
            let ex = (point["exercise"] as? [String: Any]) ?? point
            let interval = ex["interval"] as? [String: Any]
            guard let startDate = parseISODate(interval?["startTime"]) else { return nil }
            let endDate = parseISODate(interval?["endTime"])
            let duration = endDate.map { $0.timeIntervalSince(startDate) }
                ?? parseSeconds(ex["activeDuration"])
            // caloriesKcal lives under metricsSummary; firstNumeric recurses to it.
            let kcal = firstNumeric(in: ex, keys: ["caloriesKcal", "kcal", "kilocalories", "calories"])
            let type = (ex["displayName"] as? String)
                ?? prettifyType(ex["exerciseType"] as? String)
                ?? "Workout"
            return WorkoutSummary(
                activityType: type,
                startDate: startDate,
                durationSeconds: max(duration, 0),
                activeEnergyKcal: kcal > 0 ? kcal : nil
            )
        }
        return Array(workouts.sorted { $0.startDate > $1.startDate }.prefix(limit))
    }

    /// Parse an RFC3339 / ISO-8601 timestamp (with or without fractional secs).
    private static func parseISODate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFrac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Parse a seconds string like "1800s" (the exercise activeDuration format).
    private static func parseSeconds(_ value: Any?) -> Double {
        guard let s = value as? String else { return 0 }
        return Double(s.filter { $0.isNumber || $0 == "." }) ?? 0
    }

    /// "RUNNING" / "TRADITIONAL_STRENGTH_TRAINING" → "Running" / "Traditional Strength Training".
    private static func prettifyType(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Depth-first search for the first value under one of `keys` that reads as
    /// a number, descending into nested dictionaries (the metric value is often
    /// wrapped, e.g. { "steps": { "count": 512 } }).
    private static func firstNumeric(in dict: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let v = dict[key] {
                if let d = v as? Double { return d }
                if let i = v as? Int { return Double(i) }
                if let s = v as? String, let d = Double(s) { return d }
            }
        }
        for value in dict.values {
            if let nested = value as? [String: Any] {
                let found = firstNumeric(in: nested, keys: keys)
                if found != 0 { return found }
            }
        }
        return 0
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

extension GoogleHealthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

// MARK: - Google OAuth token response

private struct GoogleTokenResponse: Decodable {
    let access_token:  String
    let refresh_token: String?
    let expires_in:    Int
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
