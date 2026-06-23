// AlertsView.swift

import SwiftUI

struct AlertsView: View {

    @EnvironmentObject var alertStore: AlertStore

    var body: some View {
        NavigationStack {
            Group {
                if alertStore.isLoading && alertStore.alerts.isEmpty {
                    ProgressView("Loading alerts...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if alertStore.alerts.isEmpty {
                    ContentUnavailableView(
                        "No Active Alerts",
                        systemImage: "checkmark.shield.fill",
                        description: Text("All monitored patients are within normal parameters.")
                    )
                } else {
                    List {
                        ForEach(AlertLevel.allCases, id: \.self) { level in
                            let levelAlerts = alertStore.alerts.filter { $0.alertLevel == level }
                            if !levelAlerts.isEmpty {
                                Section(level.displayName) {
                                    ForEach(levelAlerts) { alert in
                                        NavigationLink(destination: AlertDetailView(alert: alert)) {
                                            AlertRow(alert: alert)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if alertStore.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await alertStore.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { await alertStore.refresh() }
        }
    }
}

// MARK: - Alert Row

struct AlertRow: View {
    let alert: RPMAlert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.alertLevel.systemImageName)
                .font(.title2)
                .foregroundStyle(Color(hex: alert.alertLevel.colorHex))
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(alert.description)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text("Patient: \(alert.patientID)")
                    Text("·")
                    Text(alert.timestamp.prefix(10))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Alert Detail

struct AlertDetailView: View {
    let alert: RPMAlert

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                HStack {
                    Image(systemName: alert.alertLevel.systemImageName)
                        .font(.largeTitle)
                        .foregroundStyle(Color(hex: alert.alertLevel.colorHex))
                    VStack(alignment: .leading) {
                        Text(alert.alertLevel.displayName)
                            .font(.headline)
                            .foregroundStyle(Color(hex: alert.alertLevel.colorHex))
                        Text("Patient: \(alert.patientID)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

                // Description
                InfoSection(title: "Diagnosis") {
                    Text(alert.description)
                        .font(.body)
                }

                // Required actions
                InfoSection(title: "Required Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(alert.requiredActions, id: \.self) { action in
                            Label(action.replacingOccurrences(of: "_", with: " ").capitalized,
                                  systemImage: "checkmark.circle")
                                .font(.subheadline)
                        }
                    }
                }

                // Notified parties
                InfoSection(title: "Notified") {
                    FlowLayout(spacing: 8) {
                        ForEach(alert.notifiedParties, id: \.self) { party in
                            Text(party.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.15),
                                            in: Capsule())
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Alert Detail")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helpers

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        return rows.reduce(CGSize.zero) { result, row in
            CGSize(
                width: max(result.width, row.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)),
                height: result.height + (row.first?.sizeThatFits(.unspecified).height ?? 0) + spacing
            )
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let h = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += h + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        for view in subviews {
            let w = view.sizeThatFits(.unspecified).width
            if x + w > maxWidth && !rows.last!.isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(view)
            x += w + spacing
        }
        return rows
    }
}
