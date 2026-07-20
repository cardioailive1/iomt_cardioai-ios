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

    /// Whether the subscription is set to renew again. Distinct from
    /// `isSubscribed`: a user who cancels stays subscribed (and entitled)
    /// until the paid period ends, so cancellation is only observable here.
    /// Anything asking "have they stopped their billing?" must read this,
    /// not `isSubscribed`.
    @Published private(set) var willAutoRenew: Bool = false
    @Published var purchaseError: String?

    private var updateListenerTask: Task<Void, Never>?

    init() {
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
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlement checking

    func refreshEntitlementStatus() async {
        var hasActiveSubscription = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == SubscriptionProductID.monthly {
                hasActiveSubscription = true
            }
        }
        isSubscribed = hasActiveSubscription
        await refreshRenewalStatus()
    }

    /// Reads the auto-renew flag off the subscription's renewal info. Only
    /// meaningful while a subscription is active; once it lapses entirely
    /// there is no status to read and auto-renew is trivially false.
    private func refreshRenewalStatus() async {
        guard let statuses = try? await product?.subscription?.status else {
            willAutoRenew = false
            return
        }
        willAutoRenew = statuses.contains { status in
            guard let renewalInfo = try? checkVerified(status.renewalInfo) else { return false }
            return renewalInfo.willAutoRenew
        }
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

    // nonisolated: called from the detached Transaction.updates listener as
    // well as from the main actor. It touches no instance state, so it's safe
    // to run off the main actor.
    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreKitError.notEntitled
        case .verified(let safe):
            return safe
        }
    }
}
