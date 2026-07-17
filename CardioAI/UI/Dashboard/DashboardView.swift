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
    @Published private(set) var spo2History:   [VitalSample]    = []
    @Published private(set) var systolicHistory:  [VitalSample] = []
    @Published private(set) var diastolicHistory: [VitalSample] = []
    @Published private(set) var qualityHistory:   [VitalSample] = []
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
        let now = Date()
        append(&hrHistory,        frame.heartRate, at: now)
        append(&spo2History,      frame.spo2,      at: now)
        append(&systolicHistory,  frame.systolic,  at: now)
        append(&diastolicHistory, frame.diastolic, at: now)
        append(&qualityHistory,   frame.qualityScore * 100, at: now)
    }

    /// Appends a live sample and trims to `maxHRHistory`, matching the HR buffer.
    private func append(_ buffer: inout [VitalSample], _ value: Double?, at time: Date) {
        guard let value else { return }
        buffer.append(VitalSample(timestamp: time, value: value))
        if buffer.count > maxHRHistory {
            buffer.removeFirst(buffer.count - maxHRHistory)
        }
    }

    /// Live sample history for a given vitals metric (accumulated from RPM/BLE frames).
    func history(for metric: VitalMetric) -> [VitalSample] {
        switch metric {
        case .heartRate:     return hrHistory
        case .bloodPressure: return systolicHistory
        case .oxygenSat:     return spo2History
        case .dataQuality:   return qualityHistory
        }
    }

    // MARK: Derived UI state

    /// Overall risk banner state, derived from active alerts + latest vitals.
    var riskStatus: RiskStatus {
        if alerts.contains(where: { $0.alertLevel == .critical }) { return .high }
        if alerts.contains(where: { $0.alertLevel == .high || $0.alertLevel == .medium }) { return .moderate }
        if let hr = latestFrame?.heartRate, hr < 50 || hr > 120 { return .moderate }
        return .stable
    }
}

// ── Supporting types ──────────────────────────────────────────────────────

struct VitalSample: Identifiable {
    let id        = UUID()
    let timestamp: Date
    let value:     Double
}

enum RiskStatus {
    case stable, moderate, high
    var label: String { switch self { case .stable: "Stable"; case .moderate: "Moderate"; case .high: "High" } }
    var color: Color {
        switch self {
        case .stable:   ColorPalette.cardioGreen
        case .moderate: ColorPalette.statusModerate
        case .high:     ColorPalette.cardioRed
        }
    }
}

extension AlertLevel {
    var priority: Int {
        switch self { case .critical: return 4; case .high: return 3; case .medium: return 2; case .low: return 1 }
    }
    var accentColor: Color {
        switch self {
        case .critical: return ColorPalette.cardioRed
        case .high:     return ColorPalette.cardioAmber
        case .medium:   return ColorPalette.brandBlue
        case .low:      return ColorPalette.cardioGreen
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

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning,"
        case 12..<17: return "Good afternoon,"
        case 17..<22: return "Good evening,"
        default:      return "Good night,"
        }
    }

    private var firstName: String {
        guard let name = authService.currentUser?.displayName, !name.isEmpty else { return "User" }
        return name.components(separatedBy: " ").first ?? name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // Greeting
                    VStack(alignment: .leading, spacing: 2) {
                        Text(greeting)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ColorPalette.inkSoft)
                        Text(firstName)
                            .font(.system(size: 26, weight: .heavy))
                            .tracking(-0.6)
                            .foregroundStyle(ColorPalette.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                    // Connection / device status (WS auth, BLE stream, HMAC provisioning)
                    DashboardStatusStrip(
                        deviceStreaming: pairingService.isStreaming,
                        framesSynced:    pairingService.framesSynced,
                        wsLabel:         sessionManager.connectionPatientLabel,
                        wsConnected:     sessionManager.isConnected,
                        showWSChip:      sessionManager.isProvisioned,
                        lastUpdated:     vm.lastUpdated
                    )

                    if let error = vm.lastError {
                        ErrorBanner(message: error).padding(.horizontal, 16)
                    }

                    // Hero status
                    HeroStatusCard(
                        bpm:          vm.latestFrame?.heartRate,
                        risk:         vm.riskStatus,
                        isStreaming:  pairingService.activeVitalsSource != .none,
                        sourceLabel:  pairingService.activeVitalsSource == .none
                                      ? "No source"
                                      : "Live · \(pairingService.activeVitalsSourceLabel)"
                    )
                    .padding(.horizontal, 16)

                    // Vitals
                    VitalsGridSection(vm: vm)
                        .padding(.horizontal, 16)

                    // Active alerts
                    if !vm.alerts.isEmpty {
                        AlertsCardSection(alerts: vm.alerts).padding(.horizontal, 16)
                    }

                    // System status
                    if let status = vm.bridgeStatus {
                        SystemStatusSection(status: status).padding(.horizontal, 16)
                    }

                    // Recent reports
                    if !vm.reports.isEmpty {
                        ReportsCardSection(reports: Array(vm.reports.prefix(5)))
                            .padding(.horizontal, 16)
                    }

                    Spacer(minLength: 12)
                }
                .padding(.vertical, 8)
            }
            .background(ColorPalette.screenBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { DashboardBrandMark() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if vm.isRefreshing {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await vm.refresh() } } label: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(ColorPalette.ink)
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
// MARK: - Brand mark (nav bar)
// ============================================================================

struct DashboardBrandMark: View {
    var body: some View {
        HStack(spacing: 8) {
            CardioLogoMark(size: 28)
//            (Text("Cardio").foregroundStyle(ColorPalette.ink)
//             + Text("AI").foregroundStyle(ColorPalette.brandBlue))
//                .font(.system(size: 18, weight: .heavy))
//                .tracking(-0.3)
        }
    }
}

// ============================================================================
// MARK: - Connection / device status strip
// ============================================================================

struct DashboardStatusStrip: View {
    let deviceStreaming: Bool
    let framesSynced: Int
    let wsLabel: String
    let wsConnected: Bool
    let showWSChip: Bool
    let lastUpdated: Date?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Device pairing / streaming state
                StatusChip(
                    icon: deviceStreaming ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward",
                    label: deviceStreaming ? "Device connected & syncing" : "No device connected",
                    active: deviceStreaming,
                    color: deviceStreaming ? ColorPalette.cardioGreen : ColorPalette.inkMute
                )
                // WebSocket / hardware-bridge auth state. Only shown when the
                // real-time bridge has actually been provisioned (hospital-owned
                // hardware). Most patients never touch it, so a permanent chip
                // for an unused feature is confusing noise — hide it entirely.
                // The soft `wsLabel` ("Connected"/"Not connected") is used here;
                // the raw technical detail ("Failed: HMAC secret not
                // provisioned") stays in Settings → Status for troubleshooting.
                if showWSChip {
                    StatusChip(
                        icon: "antenna.radiowaves.left.and.right",
                        label: wsLabel,
                        active: wsConnected,
                        color: wsConnected ? ColorPalette.cardioGreen : ColorPalette.inkMute
                    )
                }
                // BLE frame stream
                StatusChip(
                    icon: "dot.radiowaves.left.and.right",
                    label: deviceStreaming ? "\(framesSynced) frames" : "BLE offline",
                    active: deviceStreaming,
                    color: deviceStreaming ? ColorPalette.cardioGreen : ColorPalette.inkMute
                )
                if let ts = lastUpdated {
                    StatusChip(
                        icon: "clock",
                        label: "Updated \(relativeAgo(ts))",
                        active: false,
                        color: ColorPalette.inkMute
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func relativeAgo(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct StatusChip: View {
    let icon: String; let label: String; let active: Bool; let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(active ? ColorPalette.ink : ColorPalette.inkSoft)
                .lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(color.opacity(active ? 0.12 : 0.08), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(active ? 0.30 : 0.15), lineWidth: 1))
    }
}

// ============================================================================
// MARK: - Section title (design language: 15/700 + trailing link)
// ============================================================================

struct DSectionTitle<Trailing: View>: View {
    let title: String
    var accent: String? = nil
    var accentColor: Color = ColorPalette.cardioRed
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.1)
                    .foregroundStyle(ColorPalette.ink)
                if let accent {
                    Text("· \(accent)")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(accentColor)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 6)
    }
}

extension DSectionTitle where Trailing == EmptyView {
    init(_ title: String, accent: String? = nil, accentColor: Color = ColorPalette.cardioRed) {
        self.init(title: title, accent: accent, accentColor: accentColor) { EmptyView() }
    }
}

private struct LinkLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ColorPalette.brandBlue)
    }
}

// ============================================================================
// MARK: - Sparkline
// ============================================================================

struct Sparkline: Shape {
    let points: [Double]
    func path(in rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }
        let mn = points.min() ?? 0
        let mx = points.max() ?? 1
        let range = (mx - mn) == 0 ? 1 : (mx - mn)
        var p = Path()
        for (i, v) in points.enumerated() {
            let x = rect.width * CGFloat(i) / CGFloat(points.count - 1)
            let y = rect.height * (1 - CGFloat((v - mn) / range))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else      { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

// ============================================================================
// MARK: - Hero Status Card
// ============================================================================

struct HeroStatusCard: View {
    let bpm: Double?
    let risk: RiskStatus
    let isStreaming: Bool
    let sourceLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Top row: title + risk pill
            HStack {
                Text("TODAY'S STATUS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(risk.color).frame(width: 7, height: 7)
                    Text(risk.label)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.18), in: Capsule())
            }
            .padding(.bottom, 16)

            // BPM row
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(width: 52, height: 52)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating, isActive: isStreaming)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(bpm.map { String(format: "%.0f", $0) } ?? "--")
                            .font(.system(size: 40, weight: .heavy))
                            .tracking(-1.2)
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.spring(duration: 0.4), value: bpm)
                        Text("bpm")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isStreaming ? ColorPalette.liveGreen : .white.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(sourceLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [ColorPalette.brandBlue, ColorPalette.blueDark],
                startPoint: UnitPoint(x: 0.15, y: 0.0),
                endPoint:   UnitPoint(x: 0.85, y: 1.0)
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            // Decorative ECG pulse line
            Sparkline(points: [40, 40, 18, 62, 32, 48, 40, 40, 46, 40, 40])
                .stroke(.white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 170, height: 70)
                .padding(.top, 14).padding(.trailing, 4)
                .allowsHitTesting(false)
        }
        .shadow(color: ColorPalette.brandBlue.opacity(0.28), radius: 16, x: 0, y: 10)
    }
}

// ============================================================================
// MARK: - Vitals Grid
// ============================================================================

struct VitalsGridSection: View {
    @ObservedObject var vm: DashboardViewModel

    private var frame: RPMFrame? { vm.latestFrame }

    private func spark(_ history: [VitalSample], fallback: [Double]) -> [Double] {
        let vals = history.suffix(24).map(\.value)
        return vals.count > 1 ? Array(vals) : fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSectionTitle(title: "Vitals") {
                NavigationLink { VitalsDetailView(vm: vm) } label: { LinkLabel(text: "View all") }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                NavigationLink { VitalsDetailView(vm: vm, initialMetric: .heartRate) } label: {
                    VitalTile(
                        icon: "heart.fill",
                        tint: ColorPalette.redSoft, color: ColorPalette.cardioRed,
                        label: "Heart rate", live: true,
                        value: frame?.heartRate.map { String(format: "%.0f", $0) } ?? "--",
                        unit: "bpm", spark: spark(vm.hrHistory, fallback: [72, 74, 71, 76, 73, 70, 74, 72])
                    )
                }
                .buttonStyle(.plain)
                NavigationLink { VitalsDetailView(vm: vm, initialMetric: .bloodPressure) } label: {
                    VitalTile(
                        icon: "waveform.path.ecg",
                        tint: ColorPalette.blueSoft, color: ColorPalette.brandBlue,
                        label: "Blood pressure", live: false,
                        value: bpString, unit: "mmHg",
                        spark: spark(vm.systolicHistory, fallback: [118, 121, 119, 122, 117, 120, 119])
                    )
                }
                .buttonStyle(.plain)
                NavigationLink { VitalsDetailView(vm: vm, initialMetric: .oxygenSat) } label: {
                    VitalTile(
                        icon: "lungs.fill",
                        tint: ColorPalette.oxygenSoft, color: ColorPalette.oxygenCyan,
                        label: "Oxygen sat.", live: false,
                        value: frame?.spo2.map { String(format: "%.0f", $0) } ?? "--",
                        unit: "%", spark: spark(vm.spo2History, fallback: [97, 98, 98, 99, 97, 98, 98])
                    )
                }
                .buttonStyle(.plain)
                NavigationLink { VitalsDetailView(vm: vm, initialMetric: .dataQuality) } label: {
                    VitalTile(
                        icon: "checkmark.seal.fill",
                        tint: ColorPalette.greenSoft, color: ColorPalette.cardioGreen,
                        label: "Data quality", live: false,
                        value: frame.map { String(format: "%.0f", $0.qualityScore * 100) } ?? "--",
                        unit: "%", spark: spark(vm.qualityHistory, fallback: [88, 92, 90, 95, 93, 96, 94])
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var bpString: String {
        guard let s = frame?.systolic, let d = frame?.diastolic else { return "--" }
        return String(format: "%.0f/%.0f", s, d)
    }
}

struct VitalTile: View {
    let icon: String
    let tint: Color
    let color: Color
    let label: String
    let live: Bool
    let value: String
    let unit: String
    let spark: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint).frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ColorPalette.inkSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if live {
                    Circle().fill(ColorPalette.cardioRed).frame(width: 6, height: 6)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(value == "--" ? ColorPalette.inkMute : ColorPalette.ink)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: value)
                Text(unit)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ColorPalette.inkSoft)
            }

            Sparkline(points: spark)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(height: 22)
                .frame(maxWidth: .infinity)
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .designCard(cornerRadius: 18)
    }
}

// ============================================================================
// MARK: - Alerts Card
// ============================================================================

struct AlertsCardSection: View {
    let alerts: [RPMAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSectionTitle(title: "Active alerts",
                          accent: "\(alerts.count)",
                          accentColor: ColorPalette.cardioRed) {
                LinkLabel(text: "See all")
            }
            VStack(spacing: 0) {
                let shown = Array(alerts.prefix(4))
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, alert in
                    AlertDesignRow(alert: alert, isLast: idx == shown.count - 1)
                }
            }
            .padding(.horizontal, 18)
            .designCard(cornerRadius: 20)
        }
    }
}

struct AlertDesignRow: View {
    let alert: RPMAlert
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(alert.alertLevel.accentColor.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: alert.alertLevel.systemImageName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(alert.alertLevel.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.description)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                    Text("\(relativeTime(alert.timestamp)) · Patient \(alert.patientID)")
                        .font(.system(size: 12))
                        .foregroundStyle(ColorPalette.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ColorPalette.inkMute)
            }
            .padding(.vertical, 12)
            if !isLast {
                Rectangle().fill(ColorPalette.line).frame(height: 1)
            }
        }
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
// MARK: - System Status
// ============================================================================

struct SystemStatusSection: View {
    let status: BridgeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSectionTitle("System status")
            HStack(spacing: 10) {
                DStatTile(label: "Agents",   value: "\(status.agentCount)", color: ColorPalette.cardioGreen)
                DStatTile(label: "Queue",    value: "\(status.queueDepth)", color: queueColor)
                DStatTile(label: "Messages", value: fmtLarge(status.messageBusTotal), color: ColorPalette.brandBlue)
                DStatTile(label: "Devices",  value: "\(status.devices.active)/\(status.devices.total)", color: ColorPalette.cardioPurple)
            }
        }
    }

    private var queueColor: Color {
        status.queueDepth > 1500 ? ColorPalette.cardioRed
        : status.queueDepth > 500 ? ColorPalette.cardioAmber
        : ColorPalette.cardioGreen
    }
    private func fmtLarge(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n)/1000) : "\(n)"
    }
}

struct DStatTile: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 19, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.4), value: value)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.inkSoft)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .designCard(cornerRadius: 14)
    }
}

// ============================================================================
// MARK: - Recent Reports
// ============================================================================

struct ReportsCardSection: View {
    let reports: [ClinicalReport]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSectionTitle("Recent reports")
            VStack(spacing: 0) {
                ForEach(Array(reports.enumerated()), id: \.element.id) { idx, report in
                    ReportDesignRow(report: report, isLast: idx == reports.count - 1)
                }
            }
            .padding(.horizontal, 18)
            .designCard(cornerRadius: 20)
        }
    }
}

struct ReportDesignRow: View {
    let report: ClinicalReport
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(report.level.accentColor)
                    .frame(width: 4, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.summary)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(2)
                    Text("Patient \(report.patientID) · \(fmtTime(report.generatedAt))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
                Spacer(minLength: 6)
                Text(report.level.displayName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(report.level.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(report.level.accentColor.opacity(0.12), in: Capsule())
            }
            .padding(.vertical, 12)
            if !isLast {
                Rectangle().fill(ColorPalette.line).frame(height: 1)
            }
        }
    }

    private func fmtTime(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// ============================================================================
// MARK: - Error Banner
// ============================================================================

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ColorPalette.cardioAmber).font(.caption)
            Text("Could not refresh: \(message)")
                .font(.system(size: 12)).foregroundStyle(ColorPalette.inkSoft).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorPalette.amberSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .foregroundStyle(pairingService.isStreaming ? ColorPalette.cardioGreen : ColorPalette.inkMute)
            VStack(alignment: .leading, spacing: 3) {
                Text(pairingService.isStreaming ? "Device Syncing" : "No Device Connected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(pairingService.isStreaming ? ColorPalette.ink : ColorPalette.inkSoft)
                Text(pairingService.isStreaming
                     ? "\(pairingService.framesSynced) frames sent to IoMT backend"
                     : "Go to Connect tab to pair your device")
                    .font(.caption).foregroundStyle(ColorPalette.inkSoft)
            }
            Spacer()
            if pairingService.isStreaming {
                Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(ColorPalette.cardioGreen)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(ColorPalette.cardioGreen.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(ColorPalette.cardioGreen.opacity(0.4), lineWidth: 1))
            }
        }
        .padding()
        .designCard(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(pairingService.isStreaming ? ColorPalette.cardioGreen.opacity(0.25) : Color.clear, lineWidth: 1))
    }
}

struct ConnectionBanner: View {
    let label: String; let isConnected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(isConnected ? ColorPalette.cardioGreen : ColorPalette.cardioRed).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(ColorPalette.inkSoft)
            Spacer()
        }
    }
}

struct StatusRow: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold))
                .foregroundStyle(ColorPalette.ink)
                .contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(ColorPalette.inkSoft)
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AuthService(keychainService: KeychainService(), apiClient: APIClient(keychainService: KeychainService())))
        .environmentObject(DevicePairingService(keychainService: KeychainService(), bridgeClient: BridgeClient(keychainService: KeychainService()), apiClient: APIClient(keychainService: KeychainService()), healthKitService: HealthKitService(), fitbitService: GoogleHealthService(keychainService: KeychainService())))
        .environmentObject(SessionManager(bridgeClient: BridgeClient(keychainService: KeychainService()), keychainService: KeychainService(), authService: AuthService(keychainService: KeychainService(), apiClient: APIClient(keychainService: KeychainService()))))
}
