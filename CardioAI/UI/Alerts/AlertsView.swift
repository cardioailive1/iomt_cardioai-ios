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
                    ScrollView {
                        VStack(spacing: 20) {
                            DScreenHeader(title: "Alerts", subtitle: "Notifications")
                            DEmptyState(
                                icon: "checkmark.shield.fill",
                                tint: ColorPalette.greenSoft, color: ColorPalette.cardioGreen,
                                title: "No Active Alerts",
                                message: "All monitored patients are within normal parameters."
                            )
                        }
                        .padding(16)
                    }
                    .background(ColorPalette.screenBackground.ignoresSafeArea())
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            DScreenHeader(title: "Alerts", subtitle: "Notifications")
                            ForEach(AlertLevel.allCases, id: \.self) { level in
                                let levelAlerts = alertStore.alerts.filter { $0.alertLevel == level }
                                if !levelAlerts.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        DSectionTitle(level.displayName,
                                                      accent: "\(levelAlerts.count)",
                                                      accentColor: level.accentColor)
                                        VStack(spacing: 0) {
                                            ForEach(Array(levelAlerts.enumerated()), id: \.element.id) { idx, alert in
                                                NavigationLink(destination: AlertDetailView(alert: alert)) {
                                                    AlertDesignRow(alert: alert, isLast: idx == levelAlerts.count - 1)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 18)
                                        .designCard(cornerRadius: 20)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(ColorPalette.screenBackground.ignoresSafeArea())
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if alertStore.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await alertStore.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(ColorPalette.ink)
                        }
                    }
                }
            }
            .refreshable { await alertStore.refresh() }
        }
    }
}

// MARK: - Alert Detail

struct AlertDetailView: View {
    let alert: RPMAlert

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                HStack(spacing: 14) {
                    DIconTile(icon: alert.alertLevel.systemImageName,
                              tint: alert.alertLevel.accentColor.opacity(0.14),
                              color: alert.alertLevel.accentColor,
                              size: 52, corner: 14, iconSize: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.alertLevel.displayName)
                            .font(.system(size: 18, weight: .heavy))
                            .tracking(-0.4)
                            .foregroundStyle(alert.alertLevel.accentColor)
                        Text("Patient \(alert.patientID)")
                            .font(.system(size: 13))
                            .foregroundStyle(ColorPalette.inkSoft)
                    }
                    Spacer()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .designCard(cornerRadius: 20)

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
                                .foregroundStyle(ColorPalette.brandBlue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(ColorPalette.brandBlue.opacity(0.12),
                                            in: Capsule())
                        }
                    }
                }
            }
            .padding()
        }
        .background(ColorPalette.screenBackground.ignoresSafeArea())
        .navigationTitle("Alert Detail")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helpers

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ColorPalette.inkSoft)
                .textCase(.uppercase)
                .tracking(0.8)
            content()
                .font(.system(size: 14))
                .foregroundStyle(ColorPalette.ink)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designCard(cornerRadius: 20)
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
