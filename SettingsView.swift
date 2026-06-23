// SettingsView.swift — updated with Sign Out and Apple account info.

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
            Form {

                // ── Account ────────────────────────────────────────────────
                if let user = authService.currentUser {
                    Section("Account") {
                        LabeledContent("Name",       value: user.displayName)
                        LabeledContent("Email",      value: user.email)
                        LabeledContent("Role",       value: user.role.capitalized)
                        if let pid = user.patientID {
                            LabeledContent("Patient ID", value: pid)
                        }
                        LabeledContent("Signed in with", value: "Apple ID")
                    }
                }

                // ── Device ─────────────────────────────────────────────────
                Section("Device") {
                    if pairingService.isStreaming {
                        LabeledContent("Status", value: "Streaming")
                        if let name = pairingService.pairedDeviceName {
                            LabeledContent("Device", value: name)
                        }
                        LabeledContent("Frames synced",
                                       value: "\(pairingService.framesSynced)")
                        Button("Disconnect Device") {
                            showDisconnectConfirm = true
                        }
                        .foregroundStyle(.red)
                    } else {
                        Label("No device connected", systemImage: "sensor.tag.radiowaves.forward")
                            .foregroundStyle(.secondary)
                        NavigationLink("Connect a Device") {
                            DevicePairingView()
                        }
                    }
                }

                // ── Connection ─────────────────────────────────────────────
                Section("Backend Connection") {
                    LabeledContent("Status",      value: sessionManager.connectionLabel)
                    LabeledContent("Backend",     value: cfg.backendWSURL.host ?? "—")
                    LabeledContent("Environment", value: cfg.environment.rawValue.capitalized)
                    Button(sessionManager.isConnected ? "Disconnect" : "Reconnect") {
                        if sessionManager.isConnected {
                            sessionManager.disconnect()
                        } else {
                            sessionManager.connect()
                        }
                    }
                    .foregroundStyle(sessionManager.isConnected ? .red : .green)
                }

                // ── Security ───────────────────────────────────────────────
                Section("Security") {
                    LabeledContent("Auth method", value: "Sign in with Apple")
                    LabeledContent("WS auth",     value: "HMAC-SHA256 + JWT")
                    NavigationLink("Manage Credentials") {
                        CredentialsView()
                    }
                }

                // ── About ──────────────────────────────────────────────────
                Section("About") {
                    LabeledContent("Version",   value: cfg.appVersion)
                    LabeledContent("Build",     value: cfg.buildNumber)
                    LabeledContent("Client ID", value: cfg.clientID)
                }

                // ── Sign Out ───────────────────────────────────────────────
                Section {
                    Button("Sign Out", role: .destructive) {
                        showSignOutConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
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

// MARK: - Credentials View (HMAC secret management)

struct CredentialsView: View {

    @State private var secretInput   = ""
    @State private var statusMessage = ""
    @State private var isSuccess     = false

    private let keychainService = KeychainService()

    var body: some View {
        Form {
            Section {
                Text("The HMAC shared secret is provided by your hospital IT department. It authenticates this device to the IoMT backend over WebSocket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("HMAC Shared Secret") {
                SecureField("Enter shared secret (min 32 chars)", text: $secretInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Button("Save to Keychain") { saveSecret() }
                    .disabled(secretInput.count < 32)
            }
            if !statusMessage.isEmpty {
                Section {
                    Label(statusMessage,
                          systemImage: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isSuccess ? .green : .red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Credentials")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveSecret() {
        do {
            try keychainService.save(secretInput, for: .sharedSecret)
            statusMessage = "Secret saved securely to Keychain"
            isSuccess     = true
            secretInput   = ""
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
    @EnvironmentObject var authService: AuthService

    private let keychainService = KeychainService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                            .padding(.top, 40)
                        Text("Device Setup")
                            .font(.largeTitle.bold())
                        Text("Ask your hospital IT department for the HMAC secret to activate this device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("HMAC Shared Secret")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Minimum 32 characters", text: $secretInput)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Stored securely in iOS Keychain — never transmitted.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)

                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }

                    Button("Activate Device") {
                        guard secretInput.count >= 32 else {
                            errorMessage = "Secret must be at least 32 characters"
                            return
                        }
                        do {
                            try keychainService.save(secretInput, for: .sharedSecret)
                            // Re-evaluate isProvisioned via notification / environment
                            DependencyContainer.shared.sessionManager.connect()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(secretInput.count < 32)
                    .padding(.horizontal)

                    Button("Sign Out") { authService.signOut() }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)
            }
        }
    }
}
