// SubscriptionManager.swift
//
// Gates the entire app behind a $12.99/month subscription using StoreKit 2.
//
// SECURITY NOTE — read before relying on this in production:
// This checks entitlement via StoreKit 2's Transaction.currentEntitlements,
// which is cryptographically signed by Apple and safe against casual
// client-side tampering (unlike the old receipt-file approach). This is
// sufficient to gate the APP UI. It does NOT gate your BACKEND API — a
// sufficiently motivated user could still call your REST endpoints
// directly with a valid JWT even without an active subscription, since
// the backend has no knowledge of App Store subscription state at all.
//
// To close that gap, you'd need to:
//   1. Send Apple's App Store Server Notifications V2 to a new backend
//      webhook endpoint whenever a subscription starts/renews/expires
//   2. Store subscription status in the `users` table
//   3. Add a check in your auth middleware / route handlers that refuses
//      access for patients without an active subscription
// That's real, separate backend work — not built in this pass. Flagging
// this explicitly rather than implying the paywall is airtight.

import Foundation
import StoreKit

enum SubscriptionProductID {
    static let monthly = "com.cardioailive.rpm.premium.monthly"
}

@MainActor
final class SubscriptionManager: ObservableObject {

    @Published private(set) var isSubscribed: Bool = false
    @Published private(set) var product: Product?
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var isEligibleForTrial: Bool = false
    @Published private(set) var renewalDate: Date?
    @Published private(set) var willAutoRenew: Bool = true
    @Published var purchaseError: String?
    @Published var refundRequestMessage: String?

    private var updateListenerTask: Task<Void, Never>?
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
        updateListenerTask = listenForTransactionUpdates()
        Task {
            await loadProduct()
            await refreshEntitlementStatus()
            isLoading = false
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Load product info from App Store Connect

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [SubscriptionProductID.monthly])
            product = products.first

            // Eligibility must be checked explicitly — a user who already
            // used the trial (even on a previous subscription of the same
            // product, or after cancelling and resubscribing) is NOT
            // eligible again. Apple determines this server-side; this
            // call just reflects that determination back to the UI so we
            // never advertise "7 days free" to someone it won't actually
            // apply to.
            if let subscriptionInfo = products.first?.subscription {
                isEligibleForTrial = await subscriptionInfo.isEligibleForIntroOffer
            }
        } catch {
            purchaseError = "Could not load subscription info: \(error.localizedDescription)"
        }
    }

    /// Human-readable trial description for the paywall, e.g. "7 days
    /// free, then $12.99/month" — built from whatever introductory offer
    /// is actually configured in App Store Connect, rather than a
    /// hardcoded string, so this stays correct if the offer terms change
    /// there without a code update.
    var trialOfferDescription: String? {
        guard isEligibleForTrial,
              let offer = product?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }

        let unit: String
        switch offer.period.unit {
        case .day:   unit = offer.period.value == 1 ? "day"   : "days"
        case .week:  unit = offer.period.value == 1 ? "week"  : "weeks"
        case .month: unit = offer.period.value == 1 ? "month" : "months"
        case .year:  unit = offer.period.value == 1 ? "year"  : "years"
        @unknown default: unit = "period"
        }
        return "\(offer.period.value) \(unit) free, then \(product?.displayPrice ?? "")/month"
    }

    // MARK: - Purchase flow

    func purchase() async {
        guard let product else {
            purchaseError = "Subscription product not loaded yet — try again in a moment."
            return
        }
        purchaseError = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlementStatus()
                await linkSubscriptionToBackend(transaction: transaction)
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Purchase is pending approval (e.g. Ask to Buy) — check back once it's approved."
            @unknown default:
                break
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlementStatus()
            if let transaction = await latestTransactionForRefund() {
                await linkSubscriptionToBackend(transaction: transaction)
            }
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Tells the backend which store transaction belongs to the
    /// currently signed-in user — without this call, the backend has no
    /// way to connect Apple's originalTransactionId (used in webhook
    /// notifications) to our internal user_id at all. Best-effort: if
    /// this fails (e.g. no network right after purchase), the app UI is
    /// still unlocked via the local StoreKit 2 entitlement check: this
    /// only affects server-side enforcement, which will simply retry
    /// linking next time refreshEntitlementStatus() runs.
    private func linkSubscriptionToBackend(transaction: Transaction) async {
        do {
            _ = try await apiClient.linkSubscription(
                platform: "apple",
                transactionId: String(transaction.originalID),
                productId: transaction.productID
            )
        } catch {
            log.warning("[Subscription] failed to link subscription to backend: \(error.localizedDescription)")
        }
    }

    // MARK: - Entitlement checking

    func refreshEntitlementStatus() async {
        var hasActiveSubscription = false
        var latestTransaction: Transaction?

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == SubscriptionProductID.monthly {
                hasActiveSubscription = true
                latestTransaction = transaction
            }
        }
        isSubscribed = hasActiveSubscription
        renewalDate = latestTransaction?.expirationDate

        // Auto-renew status lives on the subscription's renewal info, not
        // the transaction itself — a subscriber can cancel (turn off
        // auto-renew) while remaining entitled through the end of the
        // current paid period, which is exactly what "Cancel" means for
        // an auto-renewable subscription: access continues until the
        // period they already paid for ends, then it simply doesn't renew.
        if let statuses = try? await product?.subscription?.status {
            for status in statuses {
                if let renewalInfo = try? checkVerified(status.renewalInfo) {
                    willAutoRenew = renewalInfo.willAutoRenew
                }
            }
        }
    }

    /// Opens Apple's native "Manage Subscriptions" screen — App Store
    /// Review requires cancellation to go through this flow, not a
    /// custom in-app cancel button. This is also where a user renews
    /// after cancelling, changes plans, etc.
    func manageSubscriptions(in scene: UIWindowScene) async {
        try? await AppStore.showManageSubscriptions(in: scene)
        await refreshEntitlementStatus()
    }

    /// Requests a refund through Apple's native refund sheet
    /// (StoreKit 2's beginRefundRequest). Apple — not this app — decides
    /// whether to actually grant it; this only opens the official request
    /// flow. There is no API for an app to directly issue its own refund
    /// for an App Store IAP purchase, by design — refund authority for
    /// purchases made through Apple's payment system belongs to Apple.
    func requestRefund(in scene: UIWindowScene) async {
        refundRequestMessage = nil
        guard let latestTransaction = await latestTransactionForRefund() else {
            refundRequestMessage = "No active purchase found to request a refund for."
            return
        }
        do {
            let result = try await latestTransaction.beginRefundRequest(in: scene)
            switch result {
            case .success:
                refundRequestMessage = "Your refund request has been submitted to Apple for review."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            refundRequestMessage = "Could not open the refund request: \(error.localizedDescription)"
        }
    }

    private func latestTransactionForRefund() async -> Transaction? {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == SubscriptionProductID.monthly {
                return transaction
            }
        }
        return nil
    }

    /// Listens for transaction updates that happen outside the direct
    /// purchase() call — renewals, cancellations, refunds, purchases made
    /// on another device with the same Apple ID, etc.
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let transaction = try? self?.checkVerified(result) else { continue }
                await transaction.finish()
                await self?.refreshEntitlementStatus()
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreKitError.notEntitled
        case .verified(let safe):
            return safe
        }
    }
}
