// DevicesView.swift

import SwiftUI

struct DevicesView: View {

    @EnvironmentObject var deviceStore: DeviceStore

    var body: some View {
        NavigationStack {
            Group {
                if let summary = deviceStore.summary, !summary.devices.isEmpty {
                    List(summary.devices) { device in
                        DeviceRow(device: device)
                    }
                    .listStyle(.insetGrouped)
                } else {
                    ContentUnavailableView(
                        "No Devices",
                        systemImage: "sensor.tag.radiowaves.forward",
                        description: Text("No IoMT devices are currently registered.")
                    )
                }
            }
            .navigationTitle("Devices")
            .refreshable { await deviceStore.refresh() }
        }
    }
}

struct DeviceRow: View {
    let device: DeviceInfo

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(device.isActive ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.id)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Patient: \(device.patientID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = device.lastDataAt {
                    Text("Last data: \(last.prefix(19).replacingOccurrences(of: "T", with: " "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(device.dataCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("frames")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
