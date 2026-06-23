// AuthService.swift
// Handles Sign in with Apple (Option C) and backend token lifecycle.
//
// Flow
// ────
//  1. Patient taps "Sign in with Apple"
//  2. Apple presents native face-ID / Touch-ID sheet
//  3. On success we receive ASAuthorizationAppleIDCredential
//  4. We exchange the Apple identityToken with our backend POST /auth/apple
//  5. Backend verifies the token with Apple, creates/loads the user record,
//     and returns { access_token, refresh_token, user { id, name, role, patient_id } }
//  6. We store access_token + refresh_token in Keychain
//  7. Subsequent launches: silent restore from Keychain → verify with backend
//  8. Token expiry (1h): silent refresh via POST /auth/refresh
//
// Apple Credential State Checks
// ──────────────────────────────
//  On every cold launch we call ASAuthorizationAppleIDProvider.getCredentialState
//  to verify Apple hasn't revoked the credential (user deleted the app from
//  Apple ID settings). If revoked → sign out immediately.

import AuthenticationServices
import Foundation
import Combine

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
    let id:         String
    let name:       String
    let email:      String
    let role:       String
    let patientID:  String?

    var isPatient: Bool     { role == "patient" }
    var displayName: String { name.isEmpty ? email : name }
}

// MARK: - Auth Service

@MainActor
final class AuthService: NSObject, ObservableObject {

    // ── Published state ────────────────────────────────────────────────────
    @Published private(set) var authState:    AuthState = .unknown
    @Published private(set) var isLoading:    Bool      = false
    @Published private(set) var errorMessage: String?   = nil

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

    // ── Init ───────────────────────────────────────────────────────────────
    init(keychainService: KeychainService, apiClient: APIClient) {
        self.keychainService = keychainService
        self.apiClient       = apiClient
        super.init()
    }

    // MARK: - Cold-Launch Restore

    /// Call on app launch. Checks Apple credential state, then restores
    /// session from Keychain or signs the user out.
    func restoreSession() async {
        guard let appleUserID = try? keychainService.read(.appleUserID) else {
            authState = .signedOut
            return
        }

        // Ask Apple whether the credential is still valid
        let credentialState = await appleCredentialState(for: appleUserID)
        switch credentialState {
        case .authorized:
            await silentTokenRefresh()
        case .revoked, .notFound:
            signOut()
        default:
            authState = .signedOut
        }
    }

    // MARK: - Sign In with Apple

    func signInWithApple() {
        let provider = ASAuthorizationAppleIDProvider()
        let request  = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate             = self
        controller.presentationContextProvider = self
        authState = .signingIn
        controller.performRequests()
    }

    // MARK: - Sign Out

    func signOut() {
        refreshTask?.cancel()
        keychainService.clearSession()
        authState = .signedOut
    }

    // MARK: - Token Refresh

    /// Silent refresh — called automatically before access token expires.
    func silentTokenRefresh() async {
        guard let refreshToken = try? keychainService.read(.refreshToken) else {
            signOut()
            return
        }
        do {
            let response = try await apiClient.refreshTokens(refreshToken: refreshToken)
            try keychainService.save(response.accessToken,  for: .accessToken)
            try keychainService.save(response.refreshToken, for: .refreshToken)
            // Reconstruct user from Keychain metadata
            if let user = restoredUserFromKeychain() {
                authState = .signedIn(user: user)
                scheduleTokenRefresh(expiresIn: response.expiresIn)
            } else {
                signOut()
            }
        } catch {
            signOut()
        }
    }

    // MARK: - Proactive Token Refresh Scheduler

    private func scheduleTokenRefresh(expiresIn: Int) {
        refreshTask?.cancel()
        // Refresh 60 seconds before expiry
        let delay = max(10, expiresIn - 60)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.silentTokenRefresh()
        }
    }

    // MARK: - Backend Exchange

    private func exchangeAppleCredential(
        identityToken: String,
        authorizationCode: String,
        fullName: PersonNameComponents?
    ) async throws -> AuthTokenResponse {
        return try await apiClient.appleSignIn(
            identityToken:     identityToken,
            authorizationCode: authorizationCode,
            firstName:         fullName?.givenName,
            lastName:          fullName?.familyName
        )
    }

    // MARK: - Keychain Helpers

    private func persistSession(
        response: AuthTokenResponse,
        appleUserID: String
    ) throws {
        try keychainService.save(response.accessToken,       for: .accessToken)
        try keychainService.save(response.refreshToken,      for: .refreshToken)
        try keychainService.save(appleUserID,                for: .appleUserID)
        try keychainService.save(response.user.id,           for: .patientID)
        try keychainService.save(response.user.role,         for: .userRole)
        try keychainService.save(response.user.name,         for: .userName)
        try keychainService.save(response.user.email,        for: .userEmail)
    }

    private func restoredUserFromKeychain() -> AuthUser? {
        guard
            let id    = try? keychainService.read(.patientID),
            let role  = try? keychainService.read(.userRole),
            let name  = try? keychainService.read(.userName),
            let email = try? keychainService.read(.userEmail)
        else { return nil }
        return AuthUser(
            id:        id,
            name:      name,
            email:     email,
            role:      role,
            patientID: role == "patient" ? id : nil
        )
    }

    // MARK: - Apple Credential State

    private func appleCredentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthService: ASAuthorizationControllerDelegate {

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let credential = authorization.credential
                    as? ASAuthorizationAppleIDCredential else { return }

            guard
                let tokenData = credential.identityToken,
                let token     = String(data: tokenData, encoding: .utf8),
                let codeData  = credential.authorizationCode,
                let code      = String(data: codeData, encoding: .utf8)
            else {
                authState = .error(message: "Apple credential data was incomplete")
                return
            }

            isLoading = true
            defer { isLoading = false }

            do {
                let response = try await exchangeAppleCredential(
                    identityToken:     token,
                    authorizationCode: code,
                    fullName:          credential.fullName
                )
                try persistSession(response: response,
                                   appleUserID: credential.user)
                authState = .signedIn(user: response.user)
                scheduleTokenRefresh(expiresIn: response.expiresIn)
            } catch {
                authState = .error(message: error.localizedDescription)
            }
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if let err = error as? ASAuthorizationError,
               err.code == .canceled {
                authState = .signedOut   // user cancelled — not an error
            } else {
                authState = .error(message: error.localizedDescription)
            }
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AuthService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
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
