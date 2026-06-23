// Stores.swift
// Observable state stores. Updated: SessionManager now depends on AuthService.

import Foundation
import Combine

// MARK: - Session Manager

@MainActor
final class SessionManager: ObservableObject {

    @Published var isConnected:     Bool   = false
    @Published var isProvisioned:   Bool   = false
    @Published var patientID:       String = ""
    @Published var connectionLabel: String = "Not connected"

    private let bridgeClient:    BridgeClient
    private let keychainService: KeychainService
    private let authService:     AuthService
    private var cancellables     = Set<AnyCancellable>()

    init(
        bridgeClient:    BridgeClient,
        keychainService: KeychainService,
        authService:     AuthService
    ) {
        self.bridgeClient    = bridgeClient
        self.keychainService = keychainService
        self.authService     = authService

        isProvisioned = keychainService.exists(.sharedSecret)
        patientID     = (try? keychainService.read(.patientID)) ?? ""

        bridgeClient.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnected     = state.isActive
                self?.connectionLabel = state.description
            }
            .store(in: &cancellables)

        // When auth state changes to signedIn, update patientID
        authService.$authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .signedIn(let user) = state {
                    self?.patientID = user.patientID ?? user.id
                }
            }
            .store(in: &cancellables)
    }

    func connect()    { bridgeClient.connect() }
    func disconnect() { bridgeClient.disconnect() }
}

// MARK: - Alert Store

@MainActor
final class AlertStore: ObservableObject {

    @Published private(set) var alerts:        [RPMAlert] = []
    @Published private(set) var isLoading:     Bool        = false
    @Published private(set) var lastError:     String?     = nil
    @Published private(set) var criticalCount: Int         = 0

    private let apiClient: APIClient
    private var pollTask:  Task<Void, Never>?

    init(apiClient: APIClient) { self.apiClient = apiClient }

    func startPolling(interval: TimeInterval = AppConfiguration.shared.apiPollIntervalSeconds) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() { pollTask?.cancel() }

    func refresh() async {
        isLoading = true; defer { isLoading = false }
        do {
            alerts        = try await apiClient.fetchAlerts()
            criticalCount = alerts.filter { $0.isCritical }.count
            lastError     = nil
        } catch { lastError = error.localizedDescription }
    }
}

// MARK: - Device Store

@MainActor
final class DeviceStore: ObservableObject {

    @Published private(set) var summary:   DeviceSummary? = nil
    @Published private(set) var status:    BridgeStatus?  = nil
    @Published private(set) var isLoading: Bool            = false
    @Published private(set) var lastError: String?         = nil

    private let apiClient: APIClient
    private var pollTask:  Task<Void, Never>?

    init(apiClient: APIClient) { self.apiClient = apiClient }

    func startPolling(interval: TimeInterval = AppConfiguration.shared.apiPollIntervalSeconds) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() { pollTask?.cancel() }

    func refresh() async {
        isLoading = true; defer { isLoading = false }
        do {
            async let s = apiClient.fetchHealth()
            async let d = apiClient.fetchDevices()
            (status, summary) = try await (s, d)
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }
}
