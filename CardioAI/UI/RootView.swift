// RootView.swift
// Auth gate → provisioning check → main app.
// Updated: checks authState before showing the main UI.

import SwiftUI

struct RootView: View {

    @EnvironmentObject var authService:    AuthService
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var alertStore:     AlertStore
    @EnvironmentObject var deviceStore:    DeviceStore
    @EnvironmentObject var pairingService: DevicePairingService
    @EnvironmentObject var subscriptionManager: SubscriptionManager

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
                // NOTE: previously gated on sessionManager.isProvisioned here,
                // which forced EVERY signed-in user (including ordinary
                // patients using Sign in with Apple) through a screen
                // demanding the hospital's HMAC shared secret before they
                // could reach the app at all. That secret authenticates the
                // real-time WebSocket bridge for hardware/BLE gateway
                // streaming — it has nothing to do with basic REST-API-based
                // app usage (Dashboard, Alerts, Devices all use the JWT
                // token from sign-in, not this secret). BridgeClient.connect()
                // already fails gracefully into a `.failed` state with a
                // clear message when unprovisioned, so it's safe to always
                // show the main app and let device provisioning remain an
                // optional step in Settings → Security → Manage Credentials
                // for the hospital-owned devices that actually need it.
                //
                // Subscription gate: added on top of the above fix, NOT a
                // reversion of it — this checks App Store subscription
                // entitlement (StoreKit 2), a completely different concern
                // from hardware-bridge provisioning. See SubscriptionManager
                // for the caveat that this only gates the app UI, not the
                // backend API.
                if subscriptionManager.isLoading {
                    SplashView(message: "Checking subscription...")
                } else if !subscriptionManager.isSubscribed {
                    PaywallView()
                        .transition(.opacity)
                } else {
                    MainTabView()
                        .transition(.opacity)
                        .onAppear {
                            sessionManager.connect()
                            alertStore.startPolling()
                            deviceStore.startPolling()
                        }
                        .task {
                            // First sign-in: show the HealthKit permission sheet.
                            // HealthKit is the ambient default vitals source until
                            // a BLE device connects (source arbitration).
                            await pairingService.requestHealthAccessAfterLogin()
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
            // White background with subtle brand-blue radial glow (cardioai-ios)
            RadialGradient(
                gradient: Gradient(colors: [ColorPalette.brandBlue.opacity(0.12), .white]),
                center: .top, startRadius: 0, endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(ColorPalette.brandBlue.opacity(0.10))
                        .frame(width: 100, height: 100)
                        .scaleEffect(animatePulse ? 1.3 : 1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                                   value: animatePulse)
//                    Image(systemName: "heart.text.square.fill")
//                        .font(.system(size: 54))
//                        .foregroundStyle(ColorPalette.brandBlue)
                    CardioLogoMark(size: 54)
                }
                .onAppear { animatePulse = true }

                HStack(spacing: 0) {
                    Text("Cardio")
                        .foregroundStyle(ColorPalette.ink)
                    Text("AI")
                        .foregroundStyle(ColorPalette.brandBlue)
                }
                .font(.system(size: 32, weight: .heavy))
                .tracking(-1.0)

                ProgressView()
                    .tint(ColorPalette.brandBlue)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(ColorPalette.inkSoft)
            }
        }
    }
}

struct CardioLogoMark: View {
    let size: CGFloat

    init(size: CGFloat = 36) {
        self.size = size
    }

    var body: some View {
        Image("cardio_logo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
