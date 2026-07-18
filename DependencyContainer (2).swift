// DependencyContainer.swift
// Centralised DI container — all singletons live here.
// Updated to include AuthService and DevicePairingService.

import Foundation

@MainActor
final class DependencyContainer: ObservableObject {

    static let shared = DependencyContainer()

    // ── Stores ─────────────────────────────────────────────────────────────
    let sessionManager:      SessionManager
    let alertStore:          AlertStore
    let deviceStore:         DeviceStore

    // ── Auth ───────────────────────────────────────────────────────────────
    let authService:         AuthService

    // ── Network ────────────────────────────────────────────────────────────
    let bridgeClient:        BridgeClient
    let apiClient:           APIClient

    // ── Device pairing ─────────────────────────────────────────────────────
    let devicePairingService: DevicePairingService

    // ── Services ───────────────────────────────────────────────────────────
    let keychainService:     KeychainService
    let healthKitService:    HealthKitService
    let fitbitService:       GoogleHealthService

    // ── Subscription (gates the entire app — see SubscriptionManager.swift) ─
    let subscriptionManager: SubscriptionManager

    private init() {
        keychainService      = KeychainService()
        apiClient            = APIClient(keychainService: keychainService)
        bridgeClient         = BridgeClient(keychainService: keychainService)
        authService          = AuthService(keychainService: keychainService,
                                           apiClient: apiClient)
        sessionManager       = SessionManager(bridgeClient: bridgeClient,
                                              keychainService: keychainService,
                                              authService: authService)
        alertStore           = AlertStore(apiClient: apiClient)
        deviceStore          = DeviceStore(apiClient: apiClient)
        healthKitService     = HealthKitService()
        fitbitService        = GoogleHealthService(keychainService: keychainService)
        devicePairingService = DevicePairingService(
            keychainService:  keychainService,
            bridgeClient:     bridgeClient,
            apiClient:        apiClient,
            healthKitService: healthKitService,
            fitbitService:    fitbitService
        )
        subscriptionManager  = SubscriptionManager()
    }
}
