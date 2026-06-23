// AppConfiguration.swift
// Runtime configuration loaded from Info.plist.
// SECRETS (shared_secret, jwt_secret) are NEVER stored here —
// they live exclusively in the iOS Keychain.

import Foundation

enum AppEnvironment: String {
    case production  = "production"
    case staging     = "staging"
    case development = "development"
}

struct AppConfiguration {

    static let shared = AppConfiguration()

    // ── Backend URLs (from Info.plist — not sensitive) ────────────────────
    let backendWSURL:   URL
    let backendAPIURL:  URL
    let environment:    AppEnvironment

    // ── App identity ───────────────────────────────────────────────────────
    let clientID:       String
    let appVersion:     String
    let buildNumber:    String

    // ── Timing ─────────────────────────────────────────────────────────────
    let heartbeatIntervalSeconds: TimeInterval = 10.0
    let reconnectMaxAttempts:     Int          = 5
    let reconnectBaseDelaySec:    TimeInterval = 2.0
    let apiPollIntervalSeconds:   TimeInterval = 5.0
    let requestTimeoutSeconds:    TimeInterval = 30.0

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]

        guard
            let wsURLString  = info["CARDIOAI_WS_URL"]  as? String,
            let apiURLString = info["CARDIOAI_API_URL"] as? String,
            let wsURL        = URL(string: wsURLString),
            let apiURL       = URL(string: apiURLString)
        else {
            fatalError(
                "CARDIOAI_WS_URL and CARDIOAI_API_URL must be set in Info.plist. " +
                "See Configuration/README.md for setup instructions."
            )
        }

        backendWSURL  = wsURL
        backendAPIURL = apiURL
        clientID      = info["CARDIOAI_CLIENT_ID"] as? String ?? "ios-client-001"
        environment   = AppEnvironment(
            rawValue: info["CARDIOAI_ENVIRONMENT"] as? String ?? "production"
        ) ?? .production
        appVersion    = info["CFBundleShortVersionString"] as? String ?? "1.0.0"
        buildNumber   = info["CFBundleVersion"] as? String ?? "1"
    }
}
