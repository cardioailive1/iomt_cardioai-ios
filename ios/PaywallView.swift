import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var authService: AuthService
    @State private var isPurchasing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                    .padding(.top, 40)

                Text("CardioAI Live Premium")
                    .font(.title2).bold()

                Text("Continuous cardiac monitoring, AI-powered alerts, and a direct line to your care team.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 12) {
                    FeatureRow(text: "Pair unlimited BLE, Apple Watch, and Fitbit devices")
                    FeatureRow(text: "Real-time 7-agent clinical AI analysis")
                    FeatureRow(text: "Direct alerts to your care team")
                    FeatureRow(text: "Full vitals history and reports")
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)

                if let product = subscriptionManager.product {
                    VStack(spacing: 6) {
                        if let trialText = subscriptionManager.trialOfferDescription {
                            Text(trialText)
                                .font(.title3).bold()
                                .foregroundStyle(.green)
                        } else {
                            Text(product.displayPrice + " / month")
                                .font(.title3).bold()
                        }
                        Text("Cancel anytime in Settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if subscriptionManager.isEligibleForTrial {
                            // Apple requires the recurring price/terms to be
                            // visible even when a free trial is offered —
                            // not just mentioned in the button label.
                            Text("After your free trial, \(product.displayPrice) will be charged monthly until cancelled.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    .padding(.top, 12)
                } else if subscriptionManager.isLoading {
                    ProgressView().padding(.top, 12)
                }

                if let error = subscriptionManager.purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button {
                    isPurchasing = true
                    Task {
                        await subscriptionManager.purchase()
                        isPurchasing = false
                    }
                } label: {
                    if isPurchasing {
                        ProgressView().tint(.white)
                    } else if subscriptionManager.isEligibleForTrial {
                        Text("Start Free Trial")
                            .fontWeight(.semibold)
                    } else {
                        Text("Subscribe — \(subscriptionManager.product?.displayPrice ?? "$12.99")/month")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .disabled(subscriptionManager.product == nil || isPurchasing)

                Button("Restore Purchases") {
                    Task { await subscriptionManager.restorePurchases() }
                }
                .font(.footnote)
                .padding(.top, 4)

                HStack(spacing: 16) {
                    Link("Terms of Use", destination: URL(string: "https://cardioailive.com/terms")!)
                    Link("Privacy Policy", destination: URL(string: "https://cardioailive.com/privacy")!)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

                Button("Sign Out") {
                    Task { await authService.signOut() }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
    }
}

private struct FeatureRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
        }
    }
}
