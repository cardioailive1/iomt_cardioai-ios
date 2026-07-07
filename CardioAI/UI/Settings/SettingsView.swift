// SettingsView.swift — dashboard design language (custom cards, no native Form).

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var authService:    AuthService
    @EnvironmentObject var pairingService: DevicePairingService
    @State private var showSignOutConfirm     = false
    @State private var showDisconnectConfirm  = false

    private let cfg = AppConfiguration.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    DScreenHeader(title: "Settings", subtitle: "Account")

                    // ── Account ────────────────────────────────────────────
                    if let user = authService.currentUser {
                        SettingsGroup(title: "Account") {
                            SettingsRow(label: "Name",  value: user.displayName)
                            SettingsDivider()
                            SettingsRow(label: "Email", value: user.email)
                            SettingsDivider()
                            SettingsRow(label: "Role",  value: user.role.capitalized)
                            if let pid = user.patientID {
                                SettingsDivider()
                                SettingsRow(label: "Patient ID", value: pid)
                            }
                            SettingsDivider()
                            SettingsRow(label: "Signed in with", value: "Apple ID")
                        }
                    }

                    // ── Device ─────────────────────────────────────────────
                    SettingsGroup(title: "Device") {
                        if pairingService.isStreaming {
                            SettingsRow(label: "Status", value: "Streaming", valueColor: ColorPalette.cardioGreen)
                            if let name = pairingService.pairedDeviceName {
                                SettingsDivider()
                                SettingsRow(label: "Device", value: name)
                            }
                            SettingsDivider()
                            SettingsRow(label: "Frames synced", value: "\(pairingService.framesSynced)")
                            SettingsDivider()
                            SettingsButtonRow(title: "Disconnect Device", role: .destructive) {
                                showDisconnectConfirm = true
                            }
                        } else {
                            SettingsRow(label: "Status", value: "No device connected", valueColor: ColorPalette.inkMute)
                            SettingsDivider()
                            SettingsLinkRow(title: "Connect a Device") { DevicePairingView() }
                        }
                    }

                    // ── Backend Connection ─────────────────────────────────
                    SettingsGroup(title: "Backend connection") {
                        SettingsRow(label: "Status",
                                    value: sessionManager.connectionLabel,
                                    valueColor: sessionManager.isConnected ? ColorPalette.cardioGreen : ColorPalette.cardioAmber)
                        SettingsDivider()
                        SettingsRow(label: "Backend", value: cfg.backendWSURL.host ?? "—")
                        SettingsDivider()
                        SettingsRow(label: "Environment", value: cfg.environment.rawValue.capitalized)
                        SettingsDivider()
                        SettingsButtonRow(
                            title: sessionManager.isConnected ? "Disconnect" : "Reconnect",
                            tint: sessionManager.isConnected ? ColorPalette.cardioRed : ColorPalette.cardioGreen
                        ) {
                            if sessionManager.isConnected { sessionManager.disconnect() }
                            else { sessionManager.connect() }
                        }
                    }

                    // ── Security ───────────────────────────────────────────
                    SettingsGroup(title: "Security") {
                        SettingsRow(label: "Auth method", value: "Sign in with Apple")
                        SettingsDivider()
                        SettingsRow(label: "WS auth", value: "HMAC-SHA256 + JWT")
                        SettingsDivider()
                        SettingsLinkRow(title: "Manage Credentials") { CredentialsView() }
                    }

                    // ── About ──────────────────────────────────────────────
                    SettingsGroup(title: "About") {
                        SettingsRow(label: "Version",   value: cfg.appVersion)
                        SettingsDivider()
                        SettingsRow(label: "Build",     value: cfg.buildNumber)
                        SettingsDivider()
                        SettingsRow(label: "Client ID", value: cfg.clientID)
                    }

                    // ── Sign Out ───────────────────────────────────────────
                    Button {
                        showSignOutConfirm = true
                    } label: {
                        Text("Sign Out")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(ColorPalette.cardioRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .designCard(cornerRadius: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(ColorPalette.screenBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Sign out of CardioAI?",
                isPresented: $showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    sessionManager.disconnect()
                    pairingService.disconnect()
                    Task { try? await DependencyContainer.shared.apiClient.logout() }
                    authService.signOut()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You will need to sign in again to access your cardiac data.")
            }
            .confirmationDialog(
                "Disconnect device?",
                isPresented: $showDisconnectConfirm,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    pairingService.disconnect()
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}

// MARK: - Settings design-language building blocks

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSectionTitle(title)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 18)
                .designCard(cornerRadius: 20)
        }
    }
}

struct SettingsRow: View {
    let label: String
    let value: String
    var valueColor: Color = ColorPalette.ink
    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(ColorPalette.inkSoft)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 13)
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(ColorPalette.line).frame(height: 1) }
}

struct SettingsButtonRow: View {
    let title: String
    var role: ButtonRole? = nil
    var tint: Color = ColorPalette.cardioRed
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(role == .destructive ? ColorPalette.cardioRed : tint)
                Spacer()
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsLinkRow<Destination: View>: View {
    let title: String
    @ViewBuilder let destination: () -> Destination
    var body: some View {
        NavigationLink(destination: destination()) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ColorPalette.brandBlue)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ColorPalette.inkMute)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Credentials View (HMAC secret management)

struct CredentialsView: View {

    @EnvironmentObject var sessionManager: SessionManager
    @State private var secretInput   = ""
    @State private var statusMessage = ""
    @State private var isSuccess     = false

    private let keychainService = KeychainService()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // Explanation card
                VStack(alignment: .leading, spacing: 10) {
                    Text("The HMAC shared secret is provided by your hospital IT department. It authenticates this device to the IoMT backend over WebSocket.")
                        .font(.system(size: 13))
                        .foregroundStyle(ColorPalette.inkSoft)
                    Text("This is only needed if your hospital has issued this device for real-time hardware/BLE gateway streaming. Everything else in the app — Dashboard, Alerts, Devices — works normally without it.")
                        .font(.system(size: 12))
                        .foregroundStyle(ColorPalette.inkMute)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .designCard(cornerRadius: 20)

                // Input card
                VStack(alignment: .leading, spacing: 10) {
                    Text("HMAC SHARED SECRET")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(ColorPalette.inkSoft)
                    SecureField("Enter shared secret (min 32 chars)", text: $secretInput)
                        .font(.system(size: 15))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(12)
                        .background(ColorPalette.screenBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ColorPalette.line, lineWidth: 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .designCard(cornerRadius: 20)

                // Save button
                Button { saveSecret() } label: {
                    Text("Save to Keychain")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(secretInput.count < 32 ? ColorPalette.inkMute : ColorPalette.brandBlue,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(secretInput.count < 32)

                if !statusMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isSuccess ? ColorPalette.cardioGreen : ColorPalette.cardioRed)
                        Text(statusMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(ColorPalette.inkSoft)
                        Spacer()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((isSuccess ? ColorPalette.greenSoft : ColorPalette.redSoft),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(ColorPalette.screenBackground.ignoresSafeArea())
        .navigationTitle("Credentials")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveSecret() {
        do {
            try keychainService.save(secretInput, for: .sharedSecret)
            statusMessage = "Secret saved securely to Keychain"
            isSuccess     = true
            secretInput   = ""
            sessionManager.refreshProvisioning()
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
            isSuccess     = false
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {

    @State private var secretInput  = ""
    @State private var errorMessage = ""
    @EnvironmentObject var authService:    AuthService
    @EnvironmentObject var sessionManager: SessionManager

    private let keychainService = KeychainService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        DIconTile(icon: "lock.shield.fill", tint: ColorPalette.blueSoft,
                                  color: ColorPalette.brandBlue, size: 72, corner: 20, iconSize: 34)
                            .padding(.top, 40)
                        Text("Device Setup")
                            .font(.system(size: 28, weight: .heavy))
                            .tracking(-0.6)
                            .foregroundStyle(ColorPalette.ink)
                        Text("Ask your hospital IT department for the HMAC secret to activate this device.")
                            .font(.system(size: 14))
                            .foregroundStyle(ColorPalette.inkSoft)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("HMAC SHARED SECRET")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(ColorPalette.inkSoft)
                        SecureField("Minimum 32 characters", text: $secretInput)
                            .font(.system(size: 15))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(ColorPalette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ColorPalette.line, lineWidth: 1))
                        Text("Stored securely in iOS Keychain — never transmitted.")
                            .font(.system(size: 12))
                            .foregroundStyle(ColorPalette.inkMute)
                    }
                    .padding(.horizontal)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(ColorPalette.cardioRed)
                    }

                    Button {
                        guard secretInput.count >= 32 else {
                            errorMessage = "Secret must be at least 32 characters"
                            return
                        }
                        do {
                            try keychainService.save(secretInput, for: .sharedSecret)
                            sessionManager.refreshProvisioning()
                            sessionManager.connect()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Text("Activate Device")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(secretInput.count < 32 ? ColorPalette.inkMute : ColorPalette.brandBlue,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(secretInput.count < 32)
                    .padding(.horizontal)

                    Button("Sign Out") { authService.signOut() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
                .padding(.bottom, 40)
            }
            .background(ColorPalette.screenBackground.ignoresSafeArea())
        }
    }
}
