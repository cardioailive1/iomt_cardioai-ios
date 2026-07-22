// PaywallView.swift
// Subscription gate shown to signed-in users without an active entitlement.
// Styled with the app's design tokens rather than system defaults so it
// matches Dashboard / Device Pairing.

import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var authService: AuthService
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var restoreSucceeded = false

    var body: some View {
        ZStack {
            ColorPalette.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {

                    header

                    featureCard

                    priceCard

                    if let error = subscriptionManager.purchaseError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(ColorPalette.cardioRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    subscribeButton

                    Button {
                        restorePurchases()
                    } label: {
                        if isRestoring {
                            ProgressView().tint(ColorPalette.brandBlue)
                        } else {
                            Text("Restore Purchases")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ColorPalette.brandBlue)
                    .disabled(isRestoring)

                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(restoreSucceeded ? ColorPalette.cardioGreen : ColorPalette.inkSoft)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: URL(string: "https://cardioailive.com/terms")!)
                        Link("Privacy Policy", destination: URL(string: "https://cardioailive.com/privacy")!)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(ColorPalette.inkSoft)

                    Button("Sign Out") {
                        authService.signOut()
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(ColorPalette.inkSoft)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .padding()
            }
        }
    }

    // MARK: - Actions

    private func restorePurchases() {
        isRestoring    = true
        restoreMessage = nil
        // Cleared up front: a stale purchaseError from an earlier failed
        // subscribe would otherwise be misreported as this restore failing.
        subscriptionManager.purchaseError = nil
        Task {
            await subscriptionManager.restorePurchases()
            if let error = subscriptionManager.purchaseError {
                restoreSucceeded = false
                restoreMessage   = error
            } else {
                // AppStore.sync() succeeding only means the lookup ran, not
                // that anything was found — the entitlement state after the
                // refresh is what actually answers the user.
                restoreSucceeded = subscriptionManager.isSubscribed
                restoreMessage   = subscriptionManager.isSubscribed
                    ? "Subscription restored."
                    : "No active subscription found for this Apple ID."
            }
            isRestoring = false
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            DIconTile(icon: "heart.text.square.fill",
                      tint: ColorPalette.blueSoft,
                      color: ColorPalette.brandBlue,
                      size: 64, corner: 18, iconSize: 30)
                .padding(.top, 24)

            Text("CardioAI Live RPM Premium")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(ColorPalette.ink)

            Text("Continuous cardiac monitoring, AI-powered alerts, and a direct line to your care team.")
                .font(.system(size: 13))
                .foregroundStyle(ColorPalette.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            FeatureRow(text: "Pair unlimited BLE and Apple Watch devices")
            FeatureRow(text: "Real-time 7-agent clinical AI analysis")
            FeatureRow(text: "Direct alerts to your care team")
            FeatureRow(text: "Full vitals history and reports")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .designCard(cornerRadius: 20)
    }

    @ViewBuilder
    private var priceCard: some View {
        if let product = subscriptionManager.product {
            VStack(spacing: 6) {
                if let trialText = subscriptionManager.trialOfferDescription {
                    Text(trialText)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ColorPalette.cardioGreen)
                } else {
                    Text("\(product.displayPrice) / month")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ColorPalette.ink)
                }

                Text("Cancel anytime in Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(ColorPalette.inkSoft)

                if subscriptionManager.isEligibleForTrial {
                    // Apple requires the recurring price/terms to be visible
                    // even when a free trial is offered — not just mentioned
                    // in the button label.
                    Text("After your free trial, \(product.displayPrice) will be charged monthly until cancelled.")
                        .font(.system(size: 11))
                        .foregroundStyle(ColorPalette.inkSoft)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .designCard(cornerRadius: 20)
        } else if subscriptionManager.isLoading {
            ProgressView().tint(ColorPalette.brandBlue).padding(.vertical, 12)
        }
    }

    private var subscribeButton: some View {
        Button {
            isPurchasing = true
            Task {
                await subscriptionManager.purchase()
                isPurchasing = false
            }
        } label: {
            Group {
                if isPurchasing {
                    ProgressView().tint(.white)
                } else if subscriptionManager.isEligibleForTrial {
                    Text("Start 7-Day Free Trial")
                } else {
                    Text("Subscribe — \(subscriptionManager.product?.displayPrice ?? "$12.99")/month")
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(ColorPalette.brandBlue, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .disabled(subscriptionManager.product == nil || isPurchasing)
        .opacity(subscriptionManager.product == nil ? 0.5 : 1)
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(ColorPalette.cardioGreen)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ColorPalette.ink)
            Spacer(minLength: 0)
        }
    }
}
