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
                ColorPalette.screenBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {

                        DScreenHeader(title: "Connect Device", subtitle: "Pairing")

                        // Status card
                        PairingStatusCard(state: pairingService.pairingState,
                                          framesSynced: pairingService.framesSynced,
                                          lastReading: pairingService.lastReading)

                        // Backend registration warning — link is up but the
                        // server didn't register the device, so sync may be
                        // incomplete.
                        if let warning = pairingService.registrationWarning {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(ColorPalette.cardioAmber)
                                    .font(.system(size: 14))
                                Text(warning)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(ColorPalette.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(ColorPalette.cardioAmber.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }

                        // Action button
                        actionButton

                        // Apple Watch & Fitbit — separate from BLE scanning,
                        // since both connect via authorization rather than
                        // discovering a nearby physical device.
                        ExternalSourcesSection()

                        // Device list (when scanning found devices)
                        if case .discovered(let devices) = pairingService.pairingState {
                            DeviceListSection(devices: devices)
                        }

                        // Live readings (when connected)
                        if pairingService.isStreaming, let reading = pairingService.lastReading {
                            LiveReadingCard(reading: reading)
                        }

                        // Instructions — replaced by an empty-result card when
                        // the last scan finished without finding any device.
                        if case .idle = pairingService.pairingState {
                            if pairingService.lastScanFoundNothing {
                                NoDevicesFoundCard {
                                    pairingService.startScanning()
                                }
                            } else {
                                PairingInstructionsCard()
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
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
                    .background(ColorPalette.brandBlue, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .font(.headline)
            }

        case .scanning:
            HStack(spacing: 12) {
                ProgressView()
                    .tint(ColorPalette.brandBlue)
                Text("Scanning for devices...")
                    .foregroundStyle(ColorPalette.brandBlue)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(ColorPalette.brandBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

        case .discovered:
            Button {
                pairingService.startScanning()
            } label: {
                Label("Scan Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(ColorPalette.brandBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(ColorPalette.brandBlue)
            }

        case .connecting(let device):
            HStack(spacing: 12) {
                ProgressView().tint(ColorPalette.cardioAmber)
                Text("Connecting to \(device.name)...")
                    .foregroundStyle(ColorPalette.cardioAmber)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(ColorPalette.cardioAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

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

// MARK: - External Sources Section (Apple Watch / Fitbit)

struct ExternalSourcesSection: View {
    @EnvironmentObject var pairingService: DevicePairingService
    @State private var showingWatchSheet  = false
    @State private var isConnectingFitbit = false

    // Fitbit hidden until FitbitService is migrated from the legacy Fitbit
    // Web API (sunsets Sept 2026, new-app registration closed) to the new
    // Google Health API. Flip to true once that rewrite lands.
    private let fitbitEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSectionTitle("Other sources")

            // Apple Watch — tapping opens the detection sheet. The watch
            // can't be found via a BLE scan (iOS restriction): it pairs to
            // the iPhone over Apple's private protocol, so detection uses
            // WatchConnectivity and data arrives via HealthKit.
            Button {
                showingWatchSheet = true
            } label: {
                HStack(spacing: 12) {
                    DIconTile(
                        icon: "applewatch",
                        tint: (pairingService.appleWatchConnected ? ColorPalette.cardioGreen : ColorPalette.brandBlue).opacity(0.14),
                        color: pairingService.appleWatchConnected ? ColorPalette.cardioGreen : ColorPalette.brandBlue,
                        size: 40, corner: 12, iconSize: 18
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Watch")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(ColorPalette.ink)
                        Text(pairingService.appleWatchConnected ? "Connected · syncing heart rate" : "Tap to find your watch")
                            .font(.system(size: 12))
                            .foregroundStyle(pairingService.appleWatchConnected ? ColorPalette.cardioGreen : ColorPalette.inkSoft)
                    }
                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
                .padding(14)
                .designCard(cornerRadius: 16)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingWatchSheet) {
                AppleWatchSheet()
            }

            // Fitbit
            if fitbitEnabled {
            HStack(spacing: 12) {
                DIconTile(
                    icon: "figure.walk.circle",
                    tint: (pairingService.fitbitConnected ? ColorPalette.cardioGreen : ColorPalette.brandBlue).opacity(0.14),
                    color: pairingService.fitbitConnected ? ColorPalette.cardioGreen : ColorPalette.brandBlue,
                    size: 40, corner: 12, iconSize: 18
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fitbit")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ColorPalette.ink)
                    Text(pairingService.fitbitConnected
                         ? "Connected · syncing heart rate"
                         : "Not connected · sign in with your Fitbit account")
                        .font(.system(size: 12))
                        .foregroundStyle(ColorPalette.inkSoft)
                    if let error = pairingService.fitbitError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(ColorPalette.cardioRed)
                    }
                }
                Spacer(minLength: 6)

                if isConnectingFitbit {
                    ProgressView().tint(ColorPalette.brandBlue)
                } else if pairingService.fitbitConnected {
                    Button("Disconnect") { pairingService.disconnectFitbit() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ColorPalette.cardioRed)
                } else {
                    Button("Connect") {
                        isConnectingFitbit = true
                        Task {
                            await pairingService.connectFitbit()
                            isConnectingFitbit = false
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ColorPalette.brandBlue)
                }
            }
            .padding(14)
            .designCard(cornerRadius: 16)
            }
        }
    }
}

// MARK: - Apple Watch Sheet
//
// Apple Watch is invisible to CoreBluetooth scans, so instead of a fake
// "scanning" list this detects the actually-paired watch via WCSession
// and shows its real name (from HealthKit heart-rate sources).

struct AppleWatchSheet: View {
    @EnvironmentObject var pairingService: DevicePairingService
    @Environment(\.dismiss) var dismiss
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            ZStack {
                ColorPalette.screenBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Apple Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { pairingService.startWatchDetection() }
    }

    @ViewBuilder
    private var content: some View {
        if !pairingService.watchPairingChecked {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(ColorPalette.brandBlue)
                    .scaleEffect(1.4)
                Text("Looking for your Apple Watch...")
                    .font(.subheadline)
                    .foregroundStyle(ColorPalette.inkSoft)
            }

        } else if !pairingService.isWatchPaired {
            VStack(spacing: 12) {
                Image(systemName: "applewatch.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(ColorPalette.inkSoft)
                Text("No Apple Watch found")
                    .font(.headline)
                    .foregroundStyle(ColorPalette.ink)
                Text("No Apple Watch is paired with this iPhone. Pair one in the Watch app, then come back here.")
                    .font(.footnote)
                    .foregroundStyle(ColorPalette.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

        } else {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    DIconTile(
                        icon: "applewatch",
                        tint: ColorPalette.blueSoft, color: ColorPalette.brandBlue,
                        size: 44, corner: 12, iconSize: 20
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pairingService.watchName ?? "Apple Watch")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(ColorPalette.ink)
                        Text(pairingService.appleWatchConnected
                             ? "Connected · syncing heart rate"
                             : "Paired with this iPhone")
                            .font(.system(size: 12))
                            .foregroundStyle(pairingService.appleWatchConnected
                                             ? ColorPalette.cardioGreen : ColorPalette.inkSoft)
                    }
                    Spacer(minLength: 6)

                    if isConnecting {
                        ProgressView().tint(ColorPalette.brandBlue)
                    } else if pairingService.appleWatchConnected {
                        Button("Disconnect") { pairingService.disconnectAppleWatch() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ColorPalette.cardioRed)
                    } else {
                        Button("Connect") {
                            isConnecting = true
                            Task {
                                await pairingService.connectAppleWatch()
                                isConnecting = false
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ColorPalette.brandBlue)
                    }
                }
                .padding(14)
                .designCard(cornerRadius: 16)

                Text("Heart rate arrives through Apple Health — the Watch can't connect over Bluetooth directly. Grant Health access when prompted.")
                    .font(.footnote)
                    .foregroundStyle(ColorPalette.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding()
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
                        .font(.system(size: 16, weight: .heavy))
                        .tracking(-0.3)
                        .foregroundStyle(ColorPalette.ink)
                    Text(statusSubtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
                Spacer()
                if framesSynced > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(framesSynced)")
                            .font(.system(size: 22, weight: .heavy))
                            .tracking(-0.4)
                            .foregroundStyle(ColorPalette.cardioGreen)
                        Text("frames synced")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ColorPalette.inkSoft)
                    }
                }
            }
        }
        .padding(18)
        .designCard(cornerRadius: 20)
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
        case .scanning:               return "Looking for nearby Bluetooth devices..."
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
            DSectionTitle("Nearby devices", accent: "\(devices.count)", accentColor: ColorPalette.brandBlue)

            ForEach(devices) { device in
                Button {
                    pairingService.connect(to: device)
                } label: {
                    HStack(spacing: 12) {
                        DIconTile(
                            icon: deviceIcon(name: device.name),
                            tint: ColorPalette.blueSoft, color: ColorPalette.brandBlue,
                            size: 40, corner: 12, iconSize: 17
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(ColorPalette.ink)
                            if let known = KnownBLEDevices.match(name: device.name) {
                                Text(known.displayLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(ColorPalette.brandBlue)
                            }
                            Text(device.id.uuidString.prefix(8).uppercased())
                                .font(.system(size: 11))
                                .foregroundStyle(ColorPalette.inkSoft)
                                .fontDesign(.monospaced)
                        }

                        Spacer(minLength: 6)

                        // Signal strength bars
                        SignalStrengthView(rssi: device.rssi)
                    }
                    .padding(14)
                    .designCard(cornerRadius: 16)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func deviceIcon(name: String) -> String {
        if let known = KnownBLEDevices.match(name: name) {
            return known.icon
        }
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
                    .fill(bar <= bars ? ColorPalette.cardioGreen : ColorPalette.line)
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
            HStack(spacing: 8) {
                DIconTile(icon: "waveform.path.ecg", tint: ColorPalette.greenSoft,
                          color: ColorPalette.cardioGreen, size: 28, corner: 8, iconSize: 13)
                Text("Live readings")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.1)
                    .foregroundStyle(ColorPalette.ink)
                Spacer()
                DPill(text: "LIVE", color: ColorPalette.cardioGreen)
            }

            Rectangle().fill(ColorPalette.line).frame(height: 1)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(reading.vitals.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                    MiniVitalCard(key: key, value: value)
                }
            }

            HStack {
                Text("Quality \(Int(reading.qualityScore * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ColorPalette.inkSoft)
                Spacer()
                Text(reading.timestamp, style: .time)
                    .font(.system(size: 12))
                    .foregroundStyle(ColorPalette.inkSoft)
            }
        }
        .padding(18)
        .designCard(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ColorPalette.cardioGreen.opacity(0.3), lineWidth: 1)
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
                .foregroundStyle(ColorPalette.brandBlue)
                .contentTransition(.numericText())
            Text(displayKey)
                .font(.caption2)
                .foregroundStyle(ColorPalette.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(ColorPalette.blueTint, in: RoundedRectangle(cornerRadius: 8))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                DIconTile(icon: "info.circle.fill", tint: ColorPalette.blueSoft,
                          color: ColorPalette.brandBlue, size: 28, corner: 8, iconSize: 13)
                Text("How to connect")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.1)
                    .foregroundStyle(ColorPalette.ink)
            }

            VStack(alignment: .leading, spacing: 10) {
                InstructionRow(number: "1", text: "Turn on your IoMT device and make sure it's charged")
                InstructionRow(number: "2", text: "Keep the device within 1 metre of your iPhone")
                InstructionRow(number: "3", text: "Tap 'Scan for Devices' above")
                InstructionRow(number: "4", text: "Select your device from the list when it appears")
                InstructionRow(number: "5", text: "Data will start syncing automatically once connected")
            }
        }
        .padding(18)
        .designCard(cornerRadius: 20)
    }
}

// MARK: - No Devices Found Card
//
// Shown in place of PairingInstructionsCard once a scan has completed with an
// empty result, so the screen doesn't fall back to generic setup steps after
// the user has already tried.

struct NoDevicesFoundCard: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                DIconTile(icon: "antenna.radiowaves.left.and.right.slash",
                          tint: ColorPalette.cardioAmber.opacity(0.14),
                          color: ColorPalette.cardioAmber, size: 28, corner: 8, iconSize: 13)
                Text("No devices found")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.1)
                    .foregroundStyle(ColorPalette.ink)
            }

            Text("No nearby health device responded to the scan.")
                .font(.system(size: 13))
                .foregroundStyle(ColorPalette.inkSoft)

            VStack(alignment: .leading, spacing: 10) {
                InstructionRow(number: "1", text: "Turn the device on and check it's charged")
                InstructionRow(number: "2", text: "Keep it within 1 metre of your iPhone")
                InstructionRow(number: "3", text: "Make sure it isn't already connected to another phone")
            }

            Button(action: onRetry) {
                Label("Scan Again", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(ColorPalette.brandBlue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(ColorPalette.brandBlue)
            }
        }
        .padding(18)
        .designCard(cornerRadius: 20)
    }
}

struct InstructionRow: View {
    let number: String
    let text:   String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(ColorPalette.brandBlue, in: Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ColorPalette.inkSoft)
            Spacer()
        }
    }
}
