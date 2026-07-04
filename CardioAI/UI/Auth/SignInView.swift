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
            // White background with subtle brand-blue radial glow (cardioai-ios)
            RadialGradient(
                gradient: Gradient(colors: [ColorPalette.brandBlue.opacity(0.12), .white]),
                center: .top, startRadius: 0, endRadius: 520
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Hero ────────────────────────────────────────────────────
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(ColorPalette.brandBlue.opacity(0.12))
                            .frame(width: 120, height: 120)
                            .scaleEffect(animatePulse ? 1.2 : 1.0)
                            .animation(
                                .easeInOut(duration: 1.8)
                                .repeatForever(autoreverses: true),
                                value: animatePulse
                            )
//                        Image(systemName: "heart.text.square.fill")
//                            .font(.system(size: 64))
//                            .foregroundStyle(ColorPalette.brandBlue)
                        CardioLogoMark(size: 64)
                    }
                    .onAppear { animatePulse = true }

                    HStack(spacing: 0) {
                        Text("Cardio").foregroundStyle(ColorPalette.ink)
                        Text("AI").foregroundStyle(ColorPalette.brandBlue)
                    }
                    .font(.system(size: 38, weight: .heavy))
                    .tracking(-1.2)

                    Text("Your heart, intelligently understood.")
                        .font(.subheadline)
                        .foregroundStyle(ColorPalette.inkSoft)
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

                // ── Sign In ───────────────────────────────────────────────────
                VStack(spacing: 16) {

                    if authService.isLoading {
                        // Show spinner while /auth/apple is in flight
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(ColorPalette.brandBlue)
                            Text("Signing in…")
                                .font(.subheadline)
                                .foregroundStyle(ColorPalette.inkSoft)
                        }
                        .frame(height: 54)

                    } else {
                        // Apple Sign In button — all logic lives in AuthService
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            Task { @MainActor in
                                await authService.handleAppleSignInResult(result)
                            }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 54)
                        .cornerRadius(12)
                        .padding(.horizontal, 28)
                    }

                    // Error display with retry
                    if case .error(let msg) = authService.authState {
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(ColorPalette.cardioRed)
                                Text(friendlyError(msg))
                                    .font(.caption)
                                    .foregroundStyle(ColorPalette.inkSoft)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 28)

                            Button("Try again") {
                                // Reset to signedOut so the button reappears
                                authService.authState = .signedOut
                            }
                            .font(.caption)
                            .foregroundStyle(ColorPalette.brandBlue)
                        }
                    }

                    Text("By signing in you agree to your hospital's privacy policy.\nYour data is encrypted and HIPAA-compliant.")
                        .font(.caption2)
                        .foregroundStyle(ColorPalette.inkSoft)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - Error message humaniser

    private func friendlyError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Connection timed out. Check your internet connection and that the CardioAI backend is running, then try again."
        }
        if lower.contains("network connection") || lower.contains("offline") || lower.contains("not connected") {
            return "No internet connection. Connect to Wi-Fi or cellular and try again."
        }
        if lower.contains("could not connect") || lower.contains("connection refused") {
            return "Cannot reach the CardioAI server. Make sure the backend is running and the API URL is correct."
        }
        if lower.contains("cancelled") {
            return "Sign-in was cancelled."
        }
        if lower.contains("401") || lower.contains("unauthori") {
            return "Authentication rejected by the server. Contact your administrator."
        }
        if lower.contains("500") || lower.contains("server error") {
            return "The server encountered an error. Please try again in a moment."
        }
        return raw
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
                    .foregroundStyle(ColorPalette.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ColorPalette.inkSoft)
            }
            Spacer()
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }
}
