// SignInView.swift
// Patient sign-in screen — Sign in with Apple (Option C).
// Shown whenever authState == .signedOut.

import SwiftUI
import AuthenticationServices

struct SignInView: View {

    @EnvironmentObject var authService: AuthService
    @State private var animatePulse = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(hex: "#060a0f"), Color(hex: "#0d1a28")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Hero ────────────────────────────────────────────────────
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 120, height: 120)
                            .scaleEffect(animatePulse ? 1.2 : 1.0)
                            .animation(
                                .easeInOut(duration: 1.8)
                                .repeatForever(autoreverses: true),
                                value: animatePulse
                            )
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.red)
                    }
                    .onAppear { animatePulse = true }

                    Text("CardioAI")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Real-time cardiac monitoring")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // ── Feature highlights ───────────────────────────────────────
                VStack(spacing: 14) {
                    FeatureRow(icon: "waveform.path.ecg",
                               color: .red,
                               title: "24/7 Heart Monitoring",
                               subtitle: "Continuous ECG, BP & SpO₂ analysis")
                    FeatureRow(icon: "bell.badge.fill",
                               color: .orange,
                               title: "Instant Critical Alerts",
                               subtitle: "Your care team notified in seconds")
                    FeatureRow(icon: "sensor.tag.radiowaves.forward.fill",
                               color: .blue,
                               title: "Wireless Device Sync",
                               subtitle: "Bluetooth wearable → AI pipeline")
                }
                .padding(.horizontal, 28)

                Spacer()

                // ── Sign In Button ────────────────────────────────────────────
                VStack(spacing: 16) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        switch result {
                        case .success(let auth):
                            guard let cred = auth.credential
                                    as? ASAuthorizationAppleIDCredential else { return }
                            Task { @MainActor in
                                guard
                                    let tokenData = cred.identityToken,
                                    let token     = String(data: tokenData, encoding: .utf8),
                                    let codeData  = cred.authorizationCode,
                                    let code      = String(data: codeData, encoding: .utf8)
                                else { return }

                                authService.isLoading = true
                                do {
                                    let response = try await DependencyContainer.shared
                                        .apiClient
                                        .appleSignIn(
                                            identityToken:     token,
                                            authorizationCode: code,
                                            firstName:         cred.fullName?.givenName,
                                            lastName:          cred.fullName?.familyName
                                        )
                                    // Store session via AuthService
                                    try DependencyContainer.shared
                                        .keychainService
                                        .save(response.accessToken, for: .accessToken)
                                    try DependencyContainer.shared
                                        .keychainService
                                        .save(response.refreshToken, for: .refreshToken)
                                    try DependencyContainer.shared
                                        .keychainService
                                        .save(cred.user, for: .appleUserID)
                                    try DependencyContainer.shared
                                        .keychainService
                                        .save(response.user.id, for: .patientID)
                                    try DependencyContainer.shared
                                        .keychainService
                                        .save(response.user.role, for: .userRole)
                                    try DependencyContainer.shared
                                        .keychainService
                                        .save(response.user.name, for: .userName)
                                    try DependencyContainer.shared
                                        .keychainService
                                        .save(response.user.email, for: .userEmail)
                                    authService.authState = .signedIn(user: response.user)
                                } catch {
                                    authService.authState = .error(message: error.localizedDescription)
                                }
                                authService.isLoading = false
                            }
                        case .failure(let err):
                            if (err as? ASAuthorizationError)?.code != .canceled {
                                authService.authState = .error(message: err.localizedDescription)
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 54)
                    .cornerRadius(12)
                    .padding(.horizontal, 28)
                    .overlay {
                        if authService.isLoading {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.4))
                                .overlay(ProgressView().tint(.white))
                                .padding(.horizontal, 28)
                        }
                    }

                    if case .error(let msg) = authService.authState {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    Text("By signing in you agree to your hospital's privacy policy.\nYour data is encrypted and HIPAA-compliant.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon:     String
    let color:    Color
    let title:    String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
