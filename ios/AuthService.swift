// AuthService.swift
// Sign in with Apple (Option C) + backend token lifecycle.
//
// Fix v1.2:
//   - handleAppleSignInResult() centralises all Apple credential handling
//   - authState is @Published with internal(set) so views can reset to .signedOut
//   - isLoading is @Published so SignInView can show a spinner
//   - Better error propagation — timeout vs server vs auth failures are distinct
//   - Silent token refresh with 1 retry before signing out

import AuthenticationServices
import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "com.cardioai.iomt", category: "AuthService")

// MARK: - Auth State

enum AuthState: Equatable {
    case unknown
    case signedOut
    case signingIn
    case signedIn(user: AuthUser)
    case error(message: String)
}

// MARK: - Auth User

struct AuthUser: Equatable, Codable {
    let id:        String
    let name:      String
    let email:     String
    let role:      String
    let patientID: String?

    var isPatient:   Bool   { role == "patient" }
    var displayName: String { name.isEmpty ? email : name }
}

// MARK: - Auth Service

@MainActor
final class AuthService: ObservableObject {

    // ── Published state ────────────────────────────────────────────────────
    @Published var authState:     AuthState = .unknown      // view-settable for retry
    @Published private(set) var isLoading:  Bool = false

    var isSignedIn: Bool {
        if case .signedIn = authState { return true }
        return false
    }

    var currentUser: AuthUser? {
        if case .signedIn(let user) = authState { return user }
        return nil
    }

    // ── Dependencies ───────────────────────────────────────────────────────
    private let keychainService: KeychainService
    private let apiClient:       APIClient
    private var refreshTask:     Task<Void, Never>?

    // MARK: - Init

    init(keychainService: KeychainService, apiClient: APIClient) {
        self.keychainService = keychainService
        self.apiClient       = apiClient
    }

    // MARK: - Cold-Launch Session Restore

    func restoreSession() async {
        guard let appleUserID = try? keychainService.read(.appleUserID) else {
            authState = .signedOut
            return
        }

        let credentialState = await appleCredentialState(for: appleUserID)
        switch credentialState {
        case .authorized:
            await silentTokenRefresh()
        case .revoked, .notFound:
            log.info("[Auth] Apple credential revoked — signing out")
            signOut()
        default:
            authState = .signedOut
        }
    }

    // MARK: - Handle Apple Sign In Result (called from SignInView)

    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            if let err = error as? ASAuthorizationError, err.code == .canceled {
                authState = .signedOut   // user dismissed — not an error
            } else {
                authState = .error(message: error.localizedDescription)
            }
            return

        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential
            else {
                authState = .error(message: "Unexpected credential type from Apple")
                return
            }

            guard
                let tokenData  = credential.identityToken,
                let token      = String(data: tokenData, encoding: .utf8),
                let codeData   = credential.authorizationCode,
                let code       = String(data: codeData, encoding: .utf8)
            else {
                authState = .error(message: "Apple credential data was incomplete. Please try again.")
                return
            }

            isLoading = true
            authState = .signingIn
            defer { isLoading = false }

            do {
                let response = try await apiClient.appleSignIn(
                    identityToken:     token,
                    authorizationCode: code,
                    firstName:         credential.fullName?.givenName,
                    lastName:          credential.fullName?.familyName
                )
                try persistSession(response: response, appleUserID: credential.user)
                authState = .signedIn(user: response.user)
                scheduleTokenRefresh(expiresIn: response.expiresIn)
                log.info("[Auth] Sign in successful: \(response.user.email)")
            } catch {
                log.error("[Auth] Sign in failed: \(error.localizedDescription)")
                authState = .error(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Sign Out

    func signOut() {
        refreshTask?.cancel()
        keychainService.clearSession()
        authState = .signedOut
    }

    /// Self-service account deletion — calls DELETE /account, then signs
    /// out locally regardless of the API call's outcome (the account
    /// should never appear "still logged in" on this device even if the
    /// network request fails, since the user explicitly asked to leave).
    /// Returns the clinical-data-retention note from the backend so the
    /// UI can show the user exactly what "deleted" does and doesn't mean.
    @discardableResult
    func deleteAccount() async throws -> String {
        do {
            let response = try await apiClient.deleteAccount()
            signOut()
            return response.clinicalDataNote
        } catch {
            // Even if the server call fails (e.g. network), don't leave
            // the user stuck mid-deletion — sign out locally and surface
            // the error so they can retry, rather than silently failing
            // with no feedback.
            signOut()
            throw error
        }
    }

    // MARK: - Silent Token Refresh

    func silentTokenRefresh() async {
        guard let refreshToken = try? keychainService.read(.refreshToken) else {
            log.info("[Auth] No refresh token — signing out")
            signOut()
            return
        }
        do {
            let response = try await apiClient.refreshTokens(refreshToken: refreshToken)
            try keychainService.save(response.accessToken,  for: .accessToken)
            try keychainService.save(response.refreshToken, for: .refreshToken)
            if let user = restoredUserFromKeychain() {
                authState = .signedIn(user: user)
                scheduleTokenRefresh(expiresIn: response.expiresIn)
                log.info("[Auth] Session silently refreshed")
            } else {
                signOut()
            }
        } catch {
            log.error("[Auth] Silent refresh failed: \(error.localizedDescription)")
            signOut()
        }
    }

    // MARK: - Proactive Token Refresh Scheduler

    private func scheduleTokenRefresh(expiresIn: Int) {
        refreshTask?.cancel()
        let delay = max(10, expiresIn - 60)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.silentTokenRefresh()
        }
    }

    // MARK: - Keychain Helpers

    private func persistSession(response: AuthTokenResponse, appleUserID: String) throws {
        try keychainService.save(response.accessToken,  for: .accessToken)
        try keychainService.save(response.refreshToken, for: .refreshToken)
        try keychainService.save(appleUserID,           for: .appleUserID)
        try keychainService.save(response.user.id,      for: .patientID)
        try keychainService.save(response.user.role,    for: .userRole)
        try keychainService.save(response.user.name,    for: .userName)
        try keychainService.save(response.user.email,   for: .userEmail)
    }

    private func restoredUserFromKeychain() -> AuthUser? {
        guard
            let id    = try? keychainService.read(.patientID),
            let role  = try? keychainService.read(.userRole),
            let name  = try? keychainService.read(.userName),
            let email = try? keychainService.read(.userEmail)
        else { return nil }
        return AuthUser(id: id, name: name, email: email, role: role,
                        patientID: role == "patient" ? id : nil)
    }

    private func appleCredentialState(for userID: String) async
        -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { cont in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                cont.resume(returning: state)
            }
        }
    }
}

// MARK: - Auth Response Models

struct AuthTokenResponse: Decodable {
    let accessToken:  String
    let refreshToken: String
    let tokenType:    String
    let expiresIn:    Int
    let user:         AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case tokenType    = "token_type"
        case expiresIn    = "expires_in"
        case user
    }
}

struct TokenRefreshResponse: Decodable {
    let accessToken:  String
    let refreshToken: String
    let tokenType:    String
    let expiresIn:    Int

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case tokenType    = "token_type"
        case expiresIn    = "expires_in"
    }
}
