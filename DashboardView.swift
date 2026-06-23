// DashboardView.swift — updated with patient greeting and BLE live data.

import SwiftUI
import Combine

struct DashboardView: View {

    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var deviceStore:    DeviceStore
    @EnvironmentObject var bridgeClient:   BridgeClient
    @EnvironmentObject var authService:    AuthService
    @EnvironmentObject var pairingService: DevicePairingService

    @State private var latestFrame:  RPMFrame?
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // Greeting
                    if let user = authService.currentUser {
                        PatientGreetingBanner(user: user,
                                              isStreaming: pairingService.isStreaming)
                    }

                    // Connection banner
                    ConnectionBanner(label: sessionManager.connectionLabel,
                                     isConnected: sessionManager.isConnected)

                    // Live vitals
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 16
                    ) {
                        VitalCard(
                            title: "Heart Rate",
                            value: latestFrame?.heartRate.map { String(format: "%.0f", $0) } ?? "--",
                            unit: "bpm", icon: "heart.fill", color: .red
                        )
                        VitalCard(
                            title: "Blood Pressure",
                            value: bpString,
                            unit: "mmHg", icon: "waveform.path.ecg", color: .orange
                        )
                        VitalCard(
                            title: "SpO₂",
                            value: latestFrame?.spo2.map { String(format: "%.0f", $0) } ?? "--",
                            unit: "%", icon: "lungs.fill", color: .blue
                        )
                        VitalCard(
                            title: "Data Quality",
                            value: latestFrame.map { String(format: "%.0f", $0.qualityScore * 100) } ?? "--",
                            unit: "%", icon: "checkmark.seal.fill", color: .green
                        )
                    }
                    .padding(.horizontal)

                    // Device sync status
                    DeviceSyncStatusCard(pairingService: pairingService)
                        .padding(.horizontal)

                    if let status = deviceStore.status {
                        BridgeStatusCard(status: status).padding(.horizontal)
                    }
                    if let summary = deviceStore.summary {
                        DeviceSummaryCard(summary: summary).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await deviceStore.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await deviceStore.refresh() }
        }
        .onAppear { subscribeToRPMData() }
    }

    private var bpString: String {
        guard let s = latestFrame?.systolic, let d = latestFrame?.diastolic else { return "--" }
        return String(format: "%.0f/%.0f", s, d)
    }

    private func subscribeToRPMData() {
        // Merge WebSocket frames AND BLE frames (both go through rpmDataSubject)
        bridgeClient.rpmDataSubject
            .receive(on: DispatchQueue.main)
            .sink { dict in self.latestFrame = RPMFrame(from: dict) }
            .store(in: &cancellables)
    }
}

// MARK: - Patient Greeting

struct PatientGreetingBanner: View {
    let user:        AuthUser
    let isStreaming: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hello, \(user.displayName.components(separatedBy: " ").first ?? user.displayName)")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Circle()
                        .fill(isStreaming ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(isStreaming ? "Device connected & syncing" : "No device connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.blue)
        }
        .padding(.horizontal)
    }
}

// MARK: - Device Sync Status Card

struct DeviceSyncStatusCard: View {
    @ObservedObject var pairingService: DevicePairingService

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: pairingService.isStreaming
                  ? "sensor.tag.radiowaves.forward.fill"
                  : "sensor.tag.radiowaves.forward")
                .font(.title2)
                .foregroundStyle(pairingService.isStreaming ? .green : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(pairingService.isStreaming ? "Device Syncing" : "No Device Connected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(pairingService.isStreaming ? .white : .secondary)
                if pairingService.isStreaming {
                    Text("\(pairingService.framesSynced) frames sent to IoMT backend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Go to Connect tab to pair your device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if pairingService.isStreaming {
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(Color.green.opacity(0.4), lineWidth: 1))
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(pairingService.isStreaming
                        ? Color.green.opacity(0.25)
                        : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Re-used components (kept from original)

struct ConnectionBanner: View {
    let label: String
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
    }
}

struct VitalCard: View {
    let title: String; let value: String; let unit: String
    let icon: String;  let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Spacer()
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.2), lineWidth: 1))
    }
}

struct BridgeStatusCard: View {
    let status: BridgeStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bridge Status", systemImage: "server.rack").font(.headline)
            Divider()
            HStack {
                StatusRow(label: "Agents",      value: "\(status.agentCount)")
                Spacer()
                StatusRow(label: "Queue Depth", value: "\(status.queueDepth)")
                Spacer()
                StatusRow(label: "Messages",    value: "\(status.messageBusTotal)")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DeviceSummaryCard: View {
    let summary: DeviceSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Devices", systemImage: "sensor.tag.radiowaves.forward.fill").font(.headline)
            Divider()
            HStack {
                StatusRow(label: "Total",    value: "\(summary.total)")
                Spacer()
                StatusRow(label: "Active",   value: "\(summary.active)")
                Spacer()
                StatusRow(label: "Inactive", value: "\(summary.inactive)")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatusRow: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
