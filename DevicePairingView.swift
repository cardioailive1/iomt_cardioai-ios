// DevicePairingView.swift
// BLE device scanning, pairing, and real-time sync status screen.
// Presented as a sheet or standalone tab for patients.

import SwiftUI
import CoreBluetooth

struct DevicePairingView: View {

    @EnvironmentObject var pairingService: DevicePairingService
    @EnvironmentObject var authService:    AuthService
    @Environment(\.dismiss) var dismiss

    @State private var showingDisconnectAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#070b10").ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {

                        // Status card
                        PairingStatusCard(state: pairingService.pairingState,
                                          framesSynced: pairingService.framesSynced,
                                          lastReading: pairingService.lastReading)

                        // Action button
                        actionButton

                        // Device list (when scanning found devices)
                        if case .discovered(let devices) = pairingService.pairingState {
                            DeviceListSection(devices: devices)
                        }

                        // Live readings (when connected)
                        if pairingService.isStreaming, let reading = pairingService.lastReading {
                            LiveReadingCard(reading: reading)
                        }

                        // Instructions
                        if case .idle = pairingService.pairingState {
                            PairingInstructionsCard()
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Connect Device")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if pairingService.isStreaming {
                        Button("Disconnect") {
                            showingDisconnectAlert = true
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .confirmationDialog(
                "Disconnect from device?",
                isPresented: $showingDisconnectAlert,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    pairingService.disconnect()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Live data streaming will stop.")
            }
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch pairingService.pairingState {
        case .idle:
            Button {
                pairingService.startScanning()
            } label: {
                Label("Scan for Devices", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .font(.headline)
            }

        case .scanning:
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("Scanning for devices...")
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))

        case .discovered:
            Button {
                pairingService.startScanning()
            } label: {
                Label("Scan Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.blue)
            }

        case .connecting(let device):
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Connecting to \(device.name)...")
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.orange.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))

        case .connected, .syncing:
            EmptyView()

        case .failed(let msg):
            VStack(spacing: 10) {
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button {
                    pairingService.startScanning()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - Pairing Status Card

struct PairingStatusCard: View {
    let state:        PairingState
    let framesSynced: Int
    let lastReading:  DeviceReading?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if framesSynced > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(framesSynced)")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.green)
                        Text("frames synced")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .idle:
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.title)
                .foregroundStyle(.gray)
        case .scanning:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(.blue)
                .symbolEffect(.variableColor.iterative)
        case .discovered:
            Image(systemName: "list.bullet.rectangle")
                .font(.title)
                .foregroundStyle(.blue)
        case .connecting:
            ProgressView()
                .tint(.orange)
                .scaleEffect(1.5)
                .frame(width: 28, height: 28)
        case .connected, .syncing:
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
                .symbolEffect(.pulse)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.red)
        }
    }

    private var statusTitle: String {
        switch state {
        case .idle:                   return "No Device Connected"
        case .scanning:               return "Scanning..."
        case .discovered(let d):      return "\(d.count) Device\(d.count == 1 ? "" : "s") Found"
        case .connecting(let d):      return "Connecting to \(d.name)"
        case .connected(let d):       return "Connected to \(d.name)"
        case .syncing(let d):         return "Syncing with \(d.name)"
        case .failed:                 return "Connection Failed"
        }
    }

    private var statusSubtitle: String {
        switch state {
        case .idle:                   return "Tap Scan to find your device"
        case .scanning:               return "Looking for CardioAI devices nearby..."
        case .discovered:             return "Select your device below"
        case .connecting:             return "Establishing secure connection..."
        case .connected:              return "Discovering device capabilities..."
        case .syncing:                return "Live data streaming to IoMT backend"
        case .failed(let msg):        return msg
        }
    }
}

// MARK: - Device List Section

struct DeviceListSection: View {
    let devices: [DiscoveredDevice]
    @EnvironmentObject var pairingService: DevicePairingService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEARBY DEVICES")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(1)

            ForEach(devices) { device in
                Button {
                    pairingService.connect(to: device)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: deviceIcon(name: device.name))
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                            Text(device.id.uuidString.prefix(8).uppercased())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                        }

                        Spacer()

                        // Signal strength bars
                        SignalStrengthView(rssi: device.rssi)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func deviceIcon(name: String) -> String {
        let n = name.lowercased()
        if n.contains("ecg") || n.contains("heart") { return "waveform.path.ecg" }
        if n.contains("bp") || n.contains("pressure") { return "heart.circle.fill" }
        if n.contains("spo") || n.contains("ox") { return "lungs.fill" }
        return "sensor.tag.radiowaves.forward.fill"
    }
}

// MARK: - Signal Strength View

struct SignalStrengthView: View {
    let rssi: Int

    private var bars: Int {
        switch rssi {
        case -60...0:    return 4
        case -70 ..< -60: return 3
        case -80 ..< -70: return 2
        default:          return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= bars ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(bar * 4))
            }
        }
        .frame(height: 18)
    }
}

// MARK: - Live Reading Card

struct LiveReadingCard: View {
    let reading: DeviceReading

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Live Readings", systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(.green)

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(reading.vitals.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                    MiniVitalCard(key: key, value: value)
                }
            }

            HStack {
                Text("Quality: \(Int(reading.qualityScore * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(reading.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}

struct MiniVitalCard: View {
    let key:   String
    let value: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(formattedValue)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(displayKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var displayKey: String {
        switch key {
        case "heart_rate": return "Heart Rate (bpm)"
        case "systolic":   return "Systolic (mmHg)"
        case "diastolic":  return "Diastolic (mmHg)"
        case "spo2":       return "SpO₂ (%)"
        default:           return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var formattedValue: String {
        String(format: "%.0f", value)
    }
}

// MARK: - Instructions Card

struct PairingInstructionsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How to connect", systemImage: "info.circle")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                InstructionRow(number: "1", text: "Turn on your IoMT device and make sure it's charged")
                InstructionRow(number: "2", text: "Keep the device within 1 metre of your iPhone")
                InstructionRow(number: "3", text: "Tap 'Scan for Devices' above")
                InstructionRow(number: "4", text: "Select your device from the list when it appears")
                InstructionRow(number: "5", text: "Data will start syncing automatically once connected")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct InstructionRow: View {
    let number: String
    let text:   String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.3), in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
