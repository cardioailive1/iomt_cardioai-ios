// RootView.swift
// Auth gate → provisioning check → main app.
// Updated: checks authState before showing the main UI.

import SwiftUI

struct RootView: View {

    @EnvironmentObject var authService:    AuthService
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var alertStore:     AlertStore
    @EnvironmentObject var deviceStore:    DeviceStore

    var body: some View {
        Group {
            switch authService.authState {

            case .unknown:
                // Cold-launch restore in progress
                SplashView()

            case .signedOut, .error:
                // Show Apple Sign In
                SignInView()
                    .transition(.opacity)

            case .signingIn:
                SplashView(message: "Signing in...")

            case .signedIn(let user):
                // Provisioned? (HMAC secret set by IT)
                if !sessionManager.isProvisioned {
                    OnboardingView()
                        .transition(.move(edge: .trailing))
                } else {
                    MainTabView()
                        .transition(.opacity)
                        .onAppear {
                            sessionManager.connect()
                            alertStore.startPolling()
                            deviceStore.startPolling()
                        }
                        .onDisappear {
                            alertStore.stopPolling()
                            deviceStore.stopPolling()
                        }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authService.isSignedIn)
    }
}

// MARK: - Splash View

struct SplashView: View {
    var message: String = "Loading..."
    @State private var animatePulse = false

    var body: some View {
        ZStack {
            Color(hex: "#060a0f").ignoresSafeArea()
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.1))
                        .frame(width: 100, height: 100)
                        .scaleEffect(animatePulse ? 1.3 : 1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                                   value: animatePulse)
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.red)
                }
                .onAppear { animatePulse = true }

                Text("CardioAI")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.secondary)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
