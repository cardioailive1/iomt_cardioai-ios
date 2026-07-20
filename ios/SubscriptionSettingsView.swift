import SwiftUI
import StoreKit

struct SubscriptionSettingsView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var authService: AuthService

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation1 = false
    @State private var showDeleteConfirmation2 = false
    @State private var isDeletingAccount = false
    @State private var deletionError: String?
    @State private var deletionSuccessMessage: String?

    var body: some View {
        Form {
            Section("Subscription Status") {
                LabeledContent("Plan", value: "CardioAI Live Premium")
                LabeledContent("Status", value: subscriptionManager.isSubscribed ? "Active" : "Inactive")
                if let renewalDate = subscriptionManager.renewalDate {
                    LabeledContent(
                        subscriptionManager.willAutoRenew ? "Renews" : "Ends",
                        value: renewalDate.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                if !subscriptionManager.willAutoRenew && subscriptionManager.isSubscribed {
                    Text("Auto-renewal is off. You'll keep access until the date above, then it will end.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Renew, Cancel, or Change Plan") {
                    Task {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            await subscriptionManager.manageSubscriptions(in: scene)
                        }
                    }
                }
            } footer: {
                // Apple requires cancellation to go through this native
                // flow, not a custom in-app "Cancel" button — this opens
                // Apple's own subscription management sheet, which also
                // handles renewing, upgrading, or downgrading.
                Text("Opens Apple's subscription management screen. Cancelling here stops future renewals — you keep access until the end of your current billing period.")
            }

            Section("Refund Policy") {
                Text("Refunds for App Store subscription purchases are issued and reviewed by Apple, not by CardioAI Live directly — this is standard for all App Store subscriptions, not specific to this app. Requesting a refund below opens Apple's official request form; Apple makes the final decision based on their refund policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Request a Refund") {
                    Task {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            await subscriptionManager.requestRefund(in: scene)
                        }
                    }
                }

                if let message = subscriptionManager.refundRequestMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Delete Account", role: .destructive) {
                    showDeleteConfirmation1 = true
                }
            } footer: {
                Text("Deletes your login and personal profile. Your subscription is managed separately by Apple — deleting your account does not automatically cancel it. Cancel above first if you don't want to be charged again.")
            }

            if let error = deletionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let success = deletionSuccessMessage {
                Text(success).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Subscription & Account")
        // Two-step confirmation for account deletion — irreversible
        // actions deserve more friction than a single tap, especially
        // for a healthcare app where "delete account" carries different
        // weight than in a typical consumer app.
        .alert("Delete your account?", isPresented: $showDeleteConfirmation1) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { showDeleteConfirmation2 = true }
        } message: {
            Text("This permanently deletes your login and profile. This cannot be undone.")
        }
        .alert("Are you absolutely sure?", isPresented: $showDeleteConfirmation2) {
            Button("Cancel", role: .cancel) {}
            Button("Delete My Account", role: .destructive) {
                Task { await performAccountDeletion() }
            }
        } message: {
            Text("Your vitals history and clinical alerts will be retained as part of your medical record, consistent with healthcare record-keeping requirements. Everything else — your login, name, and profile — will be permanently deleted.")
        }
    }

    private func performAccountDeletion() async {
        isDeletingAccount = true
        deletionError = nil
        do {
            let note = try await authService.deleteAccount()
            deletionSuccessMessage = note
            // authService.deleteAccount() already signed out locally —
            // RootView will now show the sign-in screen automatically.
        } catch {
            deletionError = "Could not delete your account: \(error.localizedDescription). Please try again or contact support."
        }
        isDeletingAccount = false
    }
}
