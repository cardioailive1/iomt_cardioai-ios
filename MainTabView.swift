// MainTabView.swift
// Updated: added Connect tab for device pairing.

import SwiftUI

struct MainTabView: View {

    @EnvironmentObject var alertStore:     AlertStore
    @EnvironmentObject var authService:    AuthService

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "heart.text.square.fill")
                }

            DevicePairingView()
                .tabItem {
                    Label("Connect", systemImage: "sensor.tag.radiowaves.forward.fill")
                }
                .badge(needsPairing ? "!" : nil)

            AlertsView()
                .badge(alertStore.criticalCount > 0 ? alertStore.criticalCount : 0)
                .tabItem {
                    Label("Alerts", systemImage: "bell.badge.fill")
                }

            DevicesView()
                .tabItem {
                    Label("Devices", systemImage: "externaldrive.connected.to.line.below.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(.green)
    }

    private var needsPairing: Bool {
        !DependencyContainer.shared.devicePairingService.isStreaming
    }
}
