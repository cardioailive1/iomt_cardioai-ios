// DevicesView.swift

import SwiftUI

struct DevicesView: View {

    @EnvironmentObject var deviceStore: DeviceStore

    private var devices: [DeviceInfo] { deviceStore.summary?.devices ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DScreenHeader(title: "Devices", subtitle: "Registered")

                    if !devices.isEmpty {
                        let active = devices.filter(\.isActive).count

                        // Summary stat strip
                        HStack(spacing: 10) {
                            DStatTile(label: "Total",  value: "\(devices.count)", color: ColorPalette.brandBlue)
                            DStatTile(label: "Active", value: "\(active)",         color: ColorPalette.cardioGreen)
                            DStatTile(label: "Offline", value: "\(devices.count - active)", color: ColorPalette.inkMute)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            DSectionTitle("Registered devices", accent: "\(devices.count)", accentColor: ColorPalette.brandBlue)
                            VStack(spacing: 0) {
                                ForEach(Array(devices.enumerated()), id: \.element.id) { idx, device in
                                    DeviceDesignRow(device: device, isLast: idx == devices.count - 1)
                                }
                            }
                            .padding(.horizontal, 16)
                            .designCard(cornerRadius: 20)
                        }
                    } else {
                        DEmptyState(
                            icon: "sensor.tag.radiowaves.forward",
                            tint: ColorPalette.blueSoft, color: ColorPalette.brandBlue,
                            title: "No Devices",
                            message: "No IoMT devices are currently registered."
                        )
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(ColorPalette.screenBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await deviceStore.refresh() }
        }
    }
}

struct DeviceDesignRow: View {
    let device: DeviceInfo
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DIconTile(
                    icon: device.isActive ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward",
                    tint: (device.isActive ? ColorPalette.cardioGreen : ColorPalette.inkMute).opacity(0.14),
                    color: device.isActive ? ColorPalette.cardioGreen : ColorPalette.inkMute
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.id)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                    Text("Patient \(device.patientID)")
                        .font(.system(size: 12))
                        .foregroundStyle(ColorPalette.inkSoft)
                        .lineLimit(1)
                    if let last = device.lastDataAt {
                        Text("Last data \(last.prefix(19).replacingOccurrences(of: "T", with: " "))")
                            .font(.system(size: 11))
                            .foregroundStyle(ColorPalette.inkMute)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    DPill(text: device.isActive ? "ACTIVE" : "OFFLINE",
                          color: device.isActive ? ColorPalette.cardioGreen : ColorPalette.inkMute)
                    Text("\(device.dataCount) frames")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ColorPalette.inkSoft)
                }
            }
            .padding(.vertical, 12)
            if !isLast {
                Rectangle().fill(ColorPalette.line).frame(height: 1)
            }
        }
    }
}
