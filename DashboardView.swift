// DashboardView.swift
// Dynamic live dashboard — polls backend every 5 s, subscribes to
// WebSocket + BLE RPM frames, animates vitals, shows alert feed,
// sparkline history, and clinical report strip.
//
// Drop-in replacement for the previous static DashboardView.swift.
// No other file changes required.

import SwiftUI
import Combine
import Charts   // requires iOS 16+ (met by iOS 17 minimum)

// ============================================================================
// MARK: - View Model
// ============================================================================

@MainActor
final class DashboardViewModel: ObservableObject {

    // ── Published state ────────────────────────────────────────────────────
    @Published private(set) var latestFrame:   RPMFrame?        = nil
    @Published private(set) var hrHistory:     [VitalSample]    = []
    @Published private(set) var alerts:        [RPMAlert]        = []
    @Published private(set) var reports:       [ClinicalReport]  = []
    @Published private(set) var bridgeStatus:  BridgeStatus?     = nil
    @Published private(set) var deviceSummary: DeviceSummary?    = nil
    @Published private(set) var isRefreshing:  Bool              = false
    @Published private(set) var lastError:     String?           = nil
    @Published private(set) var lastUpdated:   Date?             = nil

    // ── Dependencies ───────────────────────────────────────────────────────
    private let apiClient:      APIClient
    private let bridgeClient:   BridgeClient
    private let pairingService: DevicePairingService

    private var pollTask:    Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private let maxHRHistory = 60

    // MARK: Init

    init(apiClient: APIClient, bridgeClient: BridgeClient, pairingService: DevicePairingService) {
        self.apiClient      = apiClient
        self.bridgeClient   = bridgeClient
        self.pairingService = pairingService
        subscribeToRPMStream()
        subscribeToBLEReadings()
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchAll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async { await fetchAll() }

    // MARK: Fetch

    private func fetchAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let h = apiClient.fetchHealth()
            async let d = apiClient.fetchDevices()
            async let a = apiClient.fetchAlerts()
            async let r = apiClient.fetchReports()
            let (health, devices, alertList, reportList) = try await (h, d, a, r)
            bridgeStatus  = health
            deviceSummary = devices
            alerts        = alertList.sorted { $0.alertLevel.priority > $1.alertLevel.priority }
            reports       = reportList.sorted { $0.generatedAt > $1.generatedAt }
            lastError     = nil
            lastUpdated   = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: RPM Subscriptions

    private func subscribeToRPMStream() {
        bridgeClient.rpmDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dict in self?.processFrame(RPMFrame(from: dict)) }
            .store(in: &cancellables)
    }

    private func subscribeToBLEReadings() {
        pairingService.readingSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reading in
                guard let self else { return }
                let dict: [String: Any] = [
                    "device_id": reading.deviceID, "patient_id": "",
                    "timestamp": ISO8601DateFormatter().string(from: reading.timestamp),
                    "quality_score": reading.qualityScore,
                    "data": reading.vitals as [String: Any],
                ]
                self.processFrame(RPMFrame(from: dict))
            }
            .store(in: &cancellables)
    }

    private func processFrame(_ frame: RPMFrame) {
        latestFrame = frame
        if let hr = frame.heartRate {
            hrHistory.append(VitalSample(timestamp: Date(), value: hr))
            if hrHistory.count > maxHRHistory {
                hrHistory.removeFirst(hrHistory.count - maxHRHistory)
            }
        }
    }
}

// ── Supporting types ──────────────────────────────────────────────────────

struct VitalSample: Identifiable {
    let id        = UUID()
    let timestamp: Date
    let value:     Double
}

extension AlertLevel {
    var priority: Int {
        switch self { case .critical: return 4; case .high: return 3; case .medium: return 2; case .low: return 1 }
    }
    var accentColor: Color {
        switch self {
        case .critical: return Color(hex: "#F44336")
        case .high:     return Color(hex: "#FF9800")
        case .medium:   return Color(hex: "#2196F3")
        case .low:      return Color(hex: "#4CAF50")
        }
    }
    var bgColor: Color { accentColor.opacity(0.12) }
}

// ============================================================================
// MARK: - Root Dashboard View
// ============================================================================

struct DashboardView: View {

    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var authService:    AuthService
    @EnvironmentObject var bridgeClient:   BridgeClient
    @EnvironmentObject var pairingService: DevicePairingService

    @StateObject private var vm: DashboardViewModel = {
        let c = DependencyContainer.shared
        return DashboardViewModel(
            apiClient:      c.apiClient,
            bridgeClient:   c.bridgeClient,
            pairingService: c.devicePairingService
        )
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {

                    if let user = authService.currentUser {
                        PatientGreetingBanner(user: user,
                                              isStreaming: pairingService.isStreaming,
                                              lastUpdated: vm.lastUpdated)
                            .padding(.horizontal)
                    }

                    ConnectionStatusRow(
                        wsLabel:      sessionManager.connectionLabel,
                        wsConnected:  sessionManager.isConnected,
                        bleStreaming: pairingService.isStreaming,
                        framesSynced: pairingService.framesSynced
                    )
                    .padding(.horizontal)

                    if let error = vm.lastError {
                        ErrorBanner(message: error).padding(.horizontal)
                    }

                    LiveVitalsSection(frame: vm.latestFrame)

                    if !vm.hrHistory.isEmpty {
                        HRSparklineCard(history: vm.hrHistory).padding(.horizontal)
                    }

                    if !vm.alerts.isEmpty {
                        AlertFeedSection(alerts: vm.alerts)
                    }

                    if let status = vm.bridgeStatus {
                        BridgeStatsSection(status: status)
                    }

                    if !vm.reports.isEmpty {
                        RecentReportsSection(reports: Array(vm.reports.prefix(5)))
                    }

                    Spacer(minLength: 20)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if vm.isRefreshing {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await vm.refresh() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { await vm.refresh() }
        }
        .onAppear  { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }
}

// ============================================================================
// MARK: - Patient Greeting Banner
// ============================================================================

struct PatientGreetingBanner: View {
    let user: AuthUser; let isStreaming: Bool; let lastUpdated: Date?

    private var firstName: String {
        user.displayName.components(separatedBy: " ").first ?? user.displayName
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Hello, \(firstName)")
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Circle()
                        .fill(isStreaming ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(isStreaming ? "Device connected & syncing" : "No device connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let ts = lastUpdated {
                    Text("Updated \(ts, style: .relative) ago")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 52, height: 52)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.blue)
            }
        }
    }
}

// ============================================================================
// MARK: - Connection Status Row
// ============================================================================

struct ConnectionStatusRow: View {
    let wsLabel: String; let wsConnected: Bool
    let bleStreaming: Bool; let framesSynced: Int

    var body: some View {
        HStack(spacing: 10) {
            StatusChip(icon: "antenna.radiowaves.left.and.right",
                       label: wsLabel, isActive: wsConnected,
                       color: wsConnected ? .green : .secondary)
            StatusChip(icon: "sensor.tag.radiowaves.forward.fill",
                       label: bleStreaming ? "\(framesSynced) frames" : "BLE offline",
                       isActive: bleStreaming,
                       color: bleStreaming ? .green : .secondary)
        }
    }
}

struct StatusChip: View {
    let icon: String; let label: String; let isActive: Bool; let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(isActive ? .primary : .secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(isActive ? 0.1 : 0.04), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(isActive ? 0.3 : 0.1), lineWidth: 1))
    }
}

// ============================================================================
// MARK: - Error Banner
// ============================================================================

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            Text("Could not refresh: \(message)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
    }
}

// ============================================================================
// MARK: - Live Vitals Section
// ============================================================================

struct LiveVitalsSection: View {
    let frame: RPMFrame?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Live Vitals", systemImage: "waveform.path.ecg").padding(.horizontal)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                VitalCard(title: "Heart Rate",
                          value: frame?.heartRate.map { String(format: "%.0f", $0) } ?? "--",
                          unit: "bpm", icon: "heart.fill", color: hrColor)
                VitalCard(title: "Blood Pressure", value: bpString,
                          unit: "mmHg", icon: "waveform.path.ecg", color: bpColor)
                VitalCard(title: "SpO₂",
                          value: frame?.spo2.map { String(format: "%.0f", $0) } ?? "--",
                          unit: "%", icon: "lungs.fill", color: spo2Color)
                VitalCard(title: "Data Quality",
                          value: frame.map { String(format: "%.0f", $0.qualityScore * 100) } ?? "--",
                          unit: "%", icon: "checkmark.seal.fill", color: qualityColor)
            }
            .padding(.horizontal)
        }
    }

    private var hrColor: Color {
        guard let hr = frame?.heartRate else { return .secondary }
        return hr < 50 || hr > 130 ? .red : hr < 60 || hr > 100 ? .orange : .green
    }
    private var bpColor: Color {
        guard let s = frame?.systolic else { return .secondary }
        return s >= 180 ? .red : s >= 130 ? .orange : .green
    }
    private var spo2Color: Color {
        guard let o = frame?.spo2 else { return .secondary }
        return o < 90 ? .red : o < 94 ? .orange : .blue
    }
    private var qualityColor: Color {
        guard let q = frame?.qualityScore else { return .secondary }
        return q < 0.6 ? .red : q < 0.8 ? .orange : .green
    }
    private var bpString: String {
        guard let s = frame?.systolic, let d = frame?.diastolic else { return "--" }
        return String(format: "%.0f/%.0f", s, d)
    }
}

// ============================================================================
// MARK: - Vital Card
// ============================================================================

struct VitalCard: View {
    let title: String; let value: String; let unit: String
    let icon: String;  let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.subheadline).foregroundStyle(color)
                Spacer()
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(value == "--" ? Color.secondary : .primary)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: value)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Rectangle().fill(color.opacity(0.35)).frame(height: 2).clipShape(Capsule())
        }
        .padding(14)
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.15), lineWidth: 1))
    }
}

// ============================================================================
// MARK: - Heart Rate Sparkline
// ============================================================================

struct HRSparklineCard: View {
    let history: [VitalSample]

    private var latest: Double { history.last?.value ?? 0 }
    private var minVal: Double { history.map(\.value).min() ?? 0 }
    private var maxVal: Double { history.map(\.value).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Heart Rate History", systemImage: "chart.line.uptrend.xyaxis")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f bpm", latest))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.red)
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.4), value: latest)
                    Text("\(history.count) readings")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Chart(history) { s in
                LineMark(x: .value("t", s.timestamp), y: .value("HR", s.value))
                    .foregroundStyle(LinearGradient(colors: [.red.opacity(0.8), .red],
                                                    startPoint: .leading, endPoint: .trailing))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("t", s.timestamp), y: .value("HR", s.value))
                    .foregroundStyle(LinearGradient(colors: [.red.opacity(0.15), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .stride(by: 20)) { val in
                    AxisValueLabel {
                        if let v = val.as(Double.self) {
                            Text(String(format: "%.0f", v)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYScale(domain: max(0, minVal - 10)...min(250, maxVal + 10))
            .frame(height: 90)

            HStack {
                Label(String(format: "Min: %.0f", minVal), systemImage: "arrow.down")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Label(String(format: "Max: %.0f", maxVal), systemImage: "arrow.up")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// ============================================================================
// MARK: - Alert Feed Section
// ============================================================================

struct AlertFeedSection: View {
    let alerts: [RPMAlert]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Active Alerts (\(alerts.count))", systemImage: "bell.badge.fill")
                    .padding(.horizontal)
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing)
            }

            if expanded {
                VStack(spacing: 8) {
                    ForEach(alerts.prefix(5)) { alert in AlertFeedRow(alert: alert) }
                    if alerts.count > 5 {
                        Text("+ \(alerts.count - 5) more")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct AlertFeedRow: View {
    let alert: RPMAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(alert.alertLevel.bgColor).frame(width: 36, height: 36)
                Image(systemName: alert.alertLevel.systemImageName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(alert.alertLevel.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(alert.alertLevel.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(alert.alertLevel.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(alert.alertLevel.bgColor, in: Capsule())
                    Spacer()
                    Text(relativeTime(alert.timestamp)).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(alert.description).font(.subheadline).fontWeight(.medium).lineLimit(2)
                Text("Patient: \(alert.patientID)").font(.caption).foregroundStyle(.secondary)
                if !alert.requiredActions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(alert.requiredActions.prefix(3), id: \.self) { action in
                                Text(action.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.1), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(alert.alertLevel.bgColor.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(alert.alertLevel.accentColor.opacity(0.2), lineWidth: 1))
    }

    private func relativeTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let d = Date().timeIntervalSince(date)
        if d < 60   { return "\(Int(d))s ago" }
        if d < 3600 { return "\(Int(d/60))m ago" }
        return "\(Int(d/3600))h ago"
    }
}

// ============================================================================
// MARK: - Bridge Stats Section
// ============================================================================

struct BridgeStatsSection: View {
    let status: BridgeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "System Status", systemImage: "server.rack").padding(.horizontal)
            HStack(spacing: 12) {
                StatTile(label: "Agents",   value: "\(status.agentCount)",     color: .green)
                StatTile(label: "Queue",    value: "\(status.queueDepth)",     color: queueColor)
                StatTile(label: "Messages", value: fmtLarge(status.messageBusTotal), color: .blue)
                StatTile(label: "Devices",  value: "\(status.devices.active)/\(status.devices.total)", color: .purple)
            }
            .padding(.horizontal)
        }
    }

    private var queueColor: Color {
        status.queueDepth > 1500 ? .red : status.queueDepth > 500 ? .orange : .green
    }
    private func fmtLarge(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n)/1000) : "\(n)"
    }
}

struct StatTile: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.4), value: value)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.15), lineWidth: 1))
    }
}

// ============================================================================
// MARK: - Recent Reports Section
// ============================================================================

struct RecentReportsSection: View {
    let reports: [ClinicalReport]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recent Reports", systemImage: "doc.text.fill").padding(.horizontal)
            VStack(spacing: 6) {
                ForEach(reports) { report in ReportRow(report: report) }
            }
            .padding(.horizontal)
        }
    }
}

struct ReportRow: View {
    let report: ClinicalReport

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(report.level.accentColor).frame(width: 3, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.summary).font(.caption).lineLimit(2)
                Text("Patient \(report.patientID) · \(fmtTime(report.generatedAt))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(report.level.displayName)
                .font(.system(size: 9, weight: .bold)).foregroundStyle(report.level.accentColor)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(report.level.bgColor, in: Capsule())
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func fmtTime(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// ============================================================================
// MARK: - Shared sub-components (used by other screens)
// ============================================================================

struct SectionHeader: View {
    let title: String; let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
    }
}

struct DeviceSyncStatusCard: View {
    @ObservedObject var pairingService: DevicePairingService
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: pairingService.isStreaming
                  ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward")
                .font(.title2)
                .foregroundStyle(pairingService.isStreaming ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(pairingService.isStreaming ? "Device Syncing" : "No Device Connected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(pairingService.isStreaming ? .primary : .secondary)
                Text(pairingService.isStreaming
                     ? "\(pairingService.framesSynced) frames sent to IoMT backend"
                     : "Go to Connect tab to pair your device")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pairingService.isStreaming {
                Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(Color.green.opacity(0.4), lineWidth: 1))
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(pairingService.isStreaming ? Color.green.opacity(0.25) : Color.clear, lineWidth: 1))
    }
}

struct ConnectionBanner: View {
    let label: String; let isConnected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
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
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
