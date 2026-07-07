// VitalsDetailView.swift
// Full-screen vitals detail, opened from the dashboard "View all" / vital tile tap.
// Mirrors the cardioai-ios reference design (nav bar, metric tabs, range chips,
// current-value card, trend chart, min/avg/max, history) but is wired to the
// IoMT data layer: live samples accumulated in DashboardViewModel from the
// RPM WebSocket + BLE stream.

import SwiftUI

// ============================================================================
// MARK: - Metric model (scoped to what the IoMT frame actually reports)
// ============================================================================

enum VitalMetric: String, CaseIterable, Identifiable {
    case heartRate, bloodPressure, oxygenSat, dataQuality
    var id: String { rawValue }

    var label: String {
        switch self {
        case .heartRate:     return "Heart Rate"
        case .bloodPressure: return "Blood Pressure"
        case .oxygenSat:     return "Oxygen Sat."
        case .dataQuality:   return "Data Quality"
        }
    }

    var unit: String {
        switch self {
        case .heartRate:     return "bpm"
        case .bloodPressure: return "mmHg"
        case .oxygenSat:     return "%"
        case .dataQuality:   return "%"
        }
    }

    var metricDescription: String {
        switch self {
        case .heartRate:     return "Live heart rate"
        case .bloodPressure: return "Systolic / diastolic"
        case .oxygenSat:     return "Blood oxygen"
        case .dataQuality:   return "Signal quality"
        }
    }

    var targetRange: String {
        switch self {
        case .heartRate:     return "60–100"
        case .bloodPressure: return "< 130/80"
        case .oxygenSat:     return "95–100"
        case .dataQuality:   return "90–100"
        }
    }

    var color: Color {
        switch self {
        case .heartRate:     return ColorPalette.cardioRed
        case .bloodPressure: return ColorPalette.brandBlue
        case .oxygenSat:     return ColorPalette.oxygenCyan
        case .dataQuality:   return ColorPalette.cardioGreen
        }
    }

    var tint: Color {
        switch self {
        case .heartRate:     return ColorPalette.redSoft
        case .bloodPressure: return ColorPalette.blueSoft
        case .oxygenSat:     return ColorPalette.oxygenSoft
        case .dataQuality:   return ColorPalette.greenSoft
        }
    }

    var systemIcon: String {
        switch self {
        case .heartRate:     return "heart.fill"
        case .bloodPressure: return "waveform.path.ecg"
        case .oxygenSat:     return "lungs.fill"
        case .dataQuality:   return "checkmark.seal.fill"
        }
    }
}

enum VitalRange: String, CaseIterable {
    case fiveMin  = "5 Min"
    case fifteen  = "15 Min"
    case hour     = "1 Hour"
    case all      = "All"

    /// Seconds of live history to keep; `nil` == everything buffered.
    var window: TimeInterval? {
        switch self {
        case .fiveMin: return 5 * 60
        case .fifteen: return 15 * 60
        case .hour:    return 60 * 60
        case .all:     return nil
        }
    }
}

struct VitalHistoryEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let value: String
}

// ============================================================================
// MARK: - Detail view
// ============================================================================

struct VitalsDetailView: View {
    @ObservedObject var vm: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMetric: VitalMetric
    @State private var selectedRange:  VitalRange = .all

    init(vm: DashboardViewModel, initialMetric: VitalMetric = .heartRate) {
        self.vm = vm
        _selectedMetric = State(initialValue: initialMetric)
    }

    // Live samples for the selected metric, windowed by the selected range.
    private var samples: [VitalSample] {
        let all = vm.history(for: selectedMetric)
        guard let window = selectedRange.window else { return all }
        let cutoff = Date().addingTimeInterval(-window)
        return all.filter { $0.timestamp >= cutoff }
    }

    private var chartData: [Double] { samples.map(\.value) }

    var body: some View {
        ZStack {
            ColorPalette.screenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                metricScrollRow
                rangeRow
                scrollContent
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: Nav Bar

    private var navBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Circle()
                    .fill(ColorPalette.card)
                    .frame(width: 36, height: 36)
                    .shadow(color: ColorPalette.ink.opacity(0.08), radius: 8, x: 0, y: 4)
                    .overlay(
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ColorPalette.ink)
                    )
            }
            Text("Vitals")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(ColorPalette.ink)
                .tracking(-0.3)
            Spacer()
            if vm.latestFrame != nil {
                HStack(spacing: 5) {
                    Circle().fill(ColorPalette.cardioRed).frame(width: 6, height: 6)
                    Text("Live")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(ColorPalette.screenBackground)
    }

    // MARK: Metric Tabs

    private var metricScrollRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(VitalMetric.allCases) { metric in
                    Button { selectedMetric = metric } label: {
                        Text(metric.label)
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(selectedMetric == metric ? ColorPalette.textOnPrimary : ColorPalette.ink)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(
                                Capsule().fill(selectedMetric == metric ? ColorPalette.brandBlue : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: Range Chips

    private var rangeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VitalRange.allCases, id: \.self) { range in
                    Button { selectedRange = range } label: {
                        Text(range.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selectedRange == range ? ColorPalette.brandBlue : ColorPalette.inkSoft)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .overlay(
                                Capsule().stroke(
                                    selectedRange == range ? ColorPalette.brandBlue : ColorPalette.line,
                                    lineWidth: 1.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: Scroll Content

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                currentValueCard
                chartCard
                statsRow
                historySection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: Current Value Card

    private var currentValueCard: some View {
        let m = selectedMetric
        return HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(m.tint)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: m.systemIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(m.color)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(m.metricDescription.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(ColorPalette.inkSoft)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(currentValue)
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundStyle(currentValue == "--" ? ColorPalette.inkMute : ColorPalette.ink)
                        .tracking(-1.2)
                        .contentTransition(.numericText())
                    Text(m.unit)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
                Text("target \(m.targetRange)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(ColorPalette.inkSoft)
            }
            Spacer()
        }
        .padding(18)
        .designCard(cornerRadius: 20)
    }

    // MARK: Chart Card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(selectedRange.rawValue)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ColorPalette.ink)
                Text("· trend")
                    .font(.system(size: 12))
                    .foregroundStyle(ColorPalette.inkSoft)
            }
            if chartData.count < 2 {
                Text("Waiting for live data…")
                    .font(.system(size: 14))
                    .foregroundStyle(ColorPalette.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VitalsLineChart(data: chartData, color: selectedMetric.color)
            }
        }
        .padding(18)
        .designCard(cornerRadius: 20)
    }

    // MARK: Stats Row

    private var statsRow: some View {
        let m = selectedMetric
        let vals = chartData
        let stats: [(String, String)] = [
            ("Min", format(vals.min())),
            ("Avg", format(vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count))),
            ("Max", format(vals.max())),
        ]
        return HStack(spacing: 10) {
            ForEach(stats, id: \.0) { label, value in
                VStack(spacing: 4) {
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(ColorPalette.inkSoft)
                    Text(value)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(ColorPalette.ink)
                        .tracking(-0.4)
                    Text(m.unit)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ColorPalette.inkMute)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .designCard(cornerRadius: 14)
            }
        }
    }

    // MARK: History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("History")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(ColorPalette.ink)
                    .tracking(-0.1)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            if historyEntries.isEmpty {
                Text("No readings yet")
                    .font(.system(size: 14))
                    .foregroundStyle(ColorPalette.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .designCard(cornerRadius: 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(historyEntries.enumerated()), id: \.element.id) { idx, entry in
                        VitalHistoryRow(
                            entry: entry,
                            color: selectedMetric.color,
                            unit: selectedMetric.unit,
                            isLast: idx == historyEntries.count - 1
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .designCard(cornerRadius: 20)
            }
        }
    }

    // MARK: Derived values

    private var currentValue: String {
        guard let frame = vm.latestFrame else { return "--" }
        switch selectedMetric {
        case .heartRate:
            return frame.heartRate.map { String(format: "%.0f", $0) } ?? "--"
        case .bloodPressure:
            guard let s = frame.systolic, let d = frame.diastolic else { return "--" }
            return String(format: "%.0f/%.0f", s, d)
        case .oxygenSat:
            return frame.spo2.map { String(format: "%.0f", $0) } ?? "--"
        case .dataQuality:
            return String(format: "%.0f", frame.qualityScore * 100)
        }
    }

    private var historyEntries: [VitalHistoryEntry] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm:ss a"
        return samples.suffix(12).reversed().map { sample in
            VitalHistoryEntry(
                timestamp: formatter.string(from: sample.timestamp),
                value: format(sample.value)
            )
        }
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f", value)
    }
}

// ============================================================================
// MARK: - History Row
// ============================================================================

private struct VitalHistoryRow: View {
    let entry: VitalHistoryEntry
    let color: Color
    let unit: String
    let isLast: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(entry.value)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ColorPalette.ink)
                    Text(unit)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
                Text(entry.timestamp)
                    .font(.system(size: 12))
                    .foregroundStyle(ColorPalette.inkSoft)
            }
            Spacer()
            Text("Live")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.2)
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(color.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().padding(.leading, 20) }
        }
    }
}

// ============================================================================
// MARK: - Line Chart
// ============================================================================

struct VitalsLineChart: View {
    let data: [Double]
    let color: Color
    var height: CGFloat = 160

    var body: some View {
        Canvas { ctx, size in
            guard data.count > 1 else { return }
            let padL: CGFloat = 36, padR: CGFloat = 8, padT: CGFloat = 14, padB: CGFloat = 22
            let innerW = size.width - padL - padR
            let innerH = size.height - padT - padB
            let mn = data.min()!, mx = data.max()!
            let range = max(mx - mn, 1)

            let points: [CGPoint] = data.enumerated().map { i, v in
                CGPoint(
                    x: padL + CGFloat(i) / CGFloat(data.count - 1) * innerW,
                    y: padT + innerH - CGFloat((v - mn) / range) * innerH
                )
            }

            for i in 0...4 {
                let y = padT + CGFloat(i) / 4 * innerH
                var grid = Path()
                grid.move(to: CGPoint(x: padL, y: y))
                grid.addLine(to: CGPoint(x: size.width - padR, y: y))
                ctx.stroke(grid, with: .color(ColorPalette.line),
                           style: StrokeStyle(lineWidth: 1, dash: i == 4 ? [] : [3, 4]))
            }

            var area = Path()
            area.move(to: points[0])
            points.dropFirst().forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: points.last!.x, y: padT + innerH))
            area.addLine(to: CGPoint(x: points[0].x,    y: padT + innerH))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.12)))

            var line = Path()
            line.move(to: points[0])
            points.dropFirst().forEach { line.addLine(to: $0) }
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))

            let last = points.last!
            var dot = Path()
            dot.addEllipse(in: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8))
            ctx.fill(dot, with: .color(ColorPalette.card))
            ctx.stroke(dot, with: .color(color), style: StrokeStyle(lineWidth: 2.4))
        }
        .frame(height: height)
    }
}
