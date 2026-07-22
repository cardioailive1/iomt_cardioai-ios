// SettingsView.swift — dashboard design language (custom cards, no native Form).

import SwiftUI
import StoreKit

struct SettingsView: View {

    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var authService:    AuthService
    @EnvironmentObject var pairingService: DevicePairingService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @State private var showSignOutConfirm     = false
    @State private var showDisconnectConfirm  = false
    @State private var showManageSubscription = false
    @State private var showRefundSheet        = false
    @State private var showDeleteConfirm      = false
    @State private var isDeleting             = false
    @State private var deleteError: String?
    @State private var isRestoring            = false
    @State private var restoreSucceeded       = false
    @State private var restoreMessage: String?

    private let cfg = AppConfiguration.shared

    private var isPatient: Bool {
        (authService.currentUser?.role.lowercased() ?? "") == "patient"
    }

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
                            // Role and Patient ID are internal bookkeeping, not
                            // meaningful to a patient looking at their own
                            // settings — shown only for clinical staff, who may
                            // reasonably want to confirm their own role/access.
                            if !isPatient {
                                SettingsDivider()
                                SettingsRow(label: "Role",  value: user.role.capitalized)
                                if let pid = user.patientID {
                                    SettingsDivider()
                                    SettingsRow(label: "Patient ID", value: pid)
                                }
                            }
                            SettingsDivider()
                            SettingsRow(label: "Signed in with", value: "Apple ID")
                        }
                    }

                    // ── Plan & Billing ─────────────────────────────────────
                    SettingsGroup(title: "Plan & Billing") {
                        SettingsRow(
                            label: "Current plan",
                            value: subscriptionManager.isSubscribed ? "CardioAI Live RPM Premium" : "No active plan",
                            valueColor: subscriptionManager.isSubscribed ? ColorPalette.cardioGreen : ColorPalette.inkMute
                        )
                        if subscriptionManager.isSubscribed, let product = subscriptionManager.product {
                            SettingsDivider()
                            SettingsRow(label: "Price", value: "\(product.displayPrice) / month")
                        }
                        if subscriptionManager.isSubscribed, let renewalDate = subscriptionManager.renewalDate {
                            SettingsDivider()
                            SettingsRow(
                                label: subscriptionManager.willAutoRenew ? "Renews" : "Ends",
                                value: renewalDate.formatted(date: .abbreviated, time: .omitted)
                            )
                            if !subscriptionManager.willAutoRenew {
                                SettingsDivider()
                                Text("Auto-renewal is off. You'll keep access until the date above, then it ends.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ColorPalette.inkSoft)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 13)
                            }
                        }
                        SettingsDivider()
                        // Apple does not allow cancelling or changing a
                        // subscription from inside the app — this sheet is the
                        // only sanctioned route, and it hands off to the system
                        // subscription manager.
                        SettingsButtonRow(title: "Manage Subscription", tint: ColorPalette.brandBlue) {
                            showManageSubscription = true
                        }
                        if subscriptionManager.isSubscribed {
                            SettingsDivider()
                            SettingsButtonRow(title: "Request a Refund", tint: ColorPalette.brandBlue) {
                                showRefundSheet = true
                            }
                            SettingsDivider()
                            // Apple, not the app, issues App Store refunds — this
                            // only opens their official request form. Stated so
                            // users don't expect the app itself to grant it.
                            Text("Refunds are reviewed and issued by Apple, not CardioAI. This opens Apple's official request form; Apple makes the final decision.")
                                .font(.system(size: 12))
                                .foregroundStyle(ColorPalette.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 13)
                        }
                        SettingsDivider()
                        SettingsButtonRow(title: isRestoring ? "Restoring…" : "Restore Purchases",
                                          tint: ColorPalette.brandBlue) {
                            restorePurchases()
                        }
                        .disabled(isRestoring)

                        // Restore is the one action here with no visible
                        // side effect when it succeeds against an Apple ID
                        // that never bought anything — without an explicit
                        // result line it reads as a dead button.
                        if let restoreMessage {
                            SettingsDivider()
                            Text(restoreMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(restoreSucceeded ? ColorPalette.cardioGreen : ColorPalette.cardioRed)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 13)
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
                    //
                    // This entire section describes the real-time WebSocket
                    // hardware bridge — a hospital-IT-provisioned feature that
                    // ordinary patients never touch (RootView and the Dashboard
                    // connection chip already hide this same concept). Showing
                    // raw connection status, backend hostnames, and environment
                    // names to a patient is pure technical noise; clinical/admin
                    // users may still need it for support, so it stays for them.
                    if !isPatient {
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

                        // ── Security ───────────────────────────────────────
                        SettingsGroup(title: "Security") {
                            SettingsRow(label: "Auth method", value: "Sign in with Apple")
                            SettingsDivider()
                            SettingsRow(label: "WS auth", value: "HMAC-SHA256 + JWT")
                            SettingsDivider()
                            SettingsLinkRow(title: "Manage Credentials") { CredentialsView() }
                        }
                    }

                    // ── About ──────────────────────────────────────────────
                    SettingsGroup(title: "About") {
                        SettingsRow(label: "Version",   value: cfg.appVersion)
                        SettingsDivider()
                        SettingsRow(label: "Build",     value: cfg.buildNumber)
                        SettingsDivider()
                        SettingsRow(label: "Client ID", value: cfg.clientID)
                    }

                    // ── Data & Privacy ─────────────────────────────────────
                    SettingsGroup(title: "Data & Privacy") {
                        SettingsLinkRow(title: "Terms & Conditions") { TermsAndConditionsView() }
                        SettingsDivider()
                        SettingsLinkRow(title: "Privacy Policy") { PrivacyPolicyView() }
                        SettingsDivider()
                        // Apple's standard EULA — the default licence that
                        // applies to any app that doesn't supply its own.
                        SettingsExternalLinkRow(title: "Terms of Use (EULA)",
                                                url: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
                    }

                    // ── Account actions ────────────────────────────────────
                    SettingsGroup(title: "Account actions") {
                        SettingsButtonRow(title: "Sign Out", role: .destructive) {
                            showSignOutConfirm = true
                        }
                        SettingsDivider()
                        SettingsButtonRow(title: isDeleting ? "Deleting…" : "Delete Account",
                                          role: .destructive) {
                            showDeleteConfirm = true
                        }
                        .disabled(isDeleting)
                    }

                    if let deleteError {
                        Text(deleteError)
                            .font(.system(size: 12))
                            .foregroundStyle(ColorPalette.cardioRed)
                            .multilineTextAlignment(.center)
                    }
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
            .manageSubscriptionsSheet(isPresented: $showManageSubscription)
            .refundRequestSheet(for: subscriptionManager.refundTransactionID ?? 0,
                                isPresented: $showRefundSheet)
            // Transaction.updates does NOT fire when a user cancels — a
            // cancelled subscription stays entitled until the period ends, so
            // there is no transaction to observe. Without this refresh,
            // "Current plan" (and the isSubscribed check driving the delete
            // dialog) can stay stale for the rest of the session.
            .onChange(of: showManageSubscription) { _, isShowing in
                guard !isShowing else { return }
                Task { await subscriptionManager.refreshEntitlementStatus() }
            }
            .confirmationDialog(
                subscriptionManager.willAutoRenew ? "Your subscription is still active" : "Delete your CardioAI account?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                // Nothing we can call cancels an auto-renewing subscription —
                // Apple exposes no such API to developers. The only mechanism
                // is the user doing it themselves, so while billing is still
                // scheduled the destructive action is withheld and the only
                // route forward is the system sheet.
                //
                // Gated on willAutoRenew, NOT isSubscribed: a user who has
                // already cancelled stays subscribed until the period ends,
                // and keying off isSubscribed would lock them out of deleting
                // their own account for up to a month.
                if subscriptionManager.willAutoRenew {
                    Button("Cancel Subscription") { showManageSubscription = true }
                }
                // Always offered, even while billing is scheduled. Guideline
                // 5.1.1(v) requires account deletion to be reachable; making
                // it conditional on cancelling first is a rejection risk, and
                // it would trap a user who wants out but does not care about
                // the remaining period. Cancellation is presented first and
                // the consequence is spelled out — informed, not blocked.
                Button("Delete Account", role: .destructive) { deleteAccount() }
                Button("Cancel", role: .cancel) { }
            } message: {
                if subscriptionManager.willAutoRenew {
                    Text("Your subscription is set to renew. Deleting your account does not stop billing — only you can cancel it, in the App Store. We recommend cancelling first. Deleting permanently removes your login, name, and profile; your vitals history and clinical alerts are retained as part of your medical record.")
                } else {
                    Text("This permanently deletes your login, name, and profile. Your vitals history and clinical alerts are retained as part of your medical record. This cannot be undone.")
                }
            }
        }
    }

    private func restorePurchases() {
        isRestoring    = true
        restoreMessage = nil
        // Cleared up front: purchaseError persists from any earlier failure
        // (including one raised on the paywall), and a stale value would be
        // misreported as this restore failing.
        subscriptionManager.purchaseError = nil
        Task {
            await subscriptionManager.restorePurchases()
            if let error = subscriptionManager.purchaseError {
                restoreSucceeded = false
                restoreMessage   = error
            } else {
                // AppStore.sync() succeeding does not mean anything was
                // found — it only means the lookup ran. The entitlement
                // state after the refresh is what actually answers the user.
                restoreSucceeded = subscriptionManager.isSubscribed
                restoreMessage   = subscriptionManager.isSubscribed
                    ? "Subscription restored."
                    : "No active subscription found for this Apple ID."
            }
            isRestoring = false
        }
    }

    private func deleteAccount() {
        isDeleting  = true
        deleteError = nil
        Task {
            do {
                _ = try await DependencyContainer.shared.apiClient.deleteAccount()
                sessionManager.disconnect()
                pairingService.disconnect()
                authService.signOut()
            } catch {
                deleteError = "Could not delete account: \(error.localizedDescription)"
            }
            isDeleting = false
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

struct SettingsExternalLinkRow: View {
    let title: String
    let url: String
    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ColorPalette.brandBlue)
                Spacer()
                Image(systemName: "arrow.up.right")
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
