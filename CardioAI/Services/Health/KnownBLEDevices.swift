// KnownBLEDevices.swift
// A catalog of real, commonly-owned consumer BLE health devices, matched
// by substrings of their advertised Bluetooth name. Used to show accurate
// icons, device types, and friendly names during scanning — instead of
// generic "ecg_monitor" defaults for anything not immediately recognized.
//
// This does NOT change which devices show up in a scan (that's governed
// by the withServices filter in DevicePairingService.startScanning()) —
// it only improves how already-discovered devices are labeled/typed.
//
// Sources: standard BLE devices researched from current (2026) consumer
// heart rate monitor, blood pressure monitor, and pulse oximeter market —
// Polar, Wahoo, Garmin, COROS, CooSpo, CYCPLUS (heart rate); Omron,
// Withings (blood pressure); Masimo, Wellue/Viatom (pulse oximetry).
// This list isn't exhaustive — anything not matched here still works via
// the generic keyword fallback already in inferDeviceType()/deviceIcon().

import Foundation

struct KnownBLEDeviceMatch {
    let deviceType:   String  // matches backend DeviceType enum values
    let icon:         String  // SF Symbol name
    let displayLabel: String  // friendly vendor/product label
}

enum KnownBLEDevices {

    // Order matters only in that the first matching entry wins — kept
    // roughly most-specific-first to avoid short substrings (like "hr")
    // accidentally matching an unrelated device.
    private static let catalog: [(matchers: [String], match: KnownBLEDeviceMatch)] = [
        // ── Heart rate chest straps / armbands ──────────────────────────
        (["polar h10", "polar h9", "polar verity", "polar oh1"],
         .init(deviceType: "ecg_monitor", icon: "waveform.path.ecg", displayLabel: "Polar Heart Rate Monitor")),
        (["wahoo tickr", "wahoo trackr"],
         .init(deviceType: "ecg_monitor", icon: "waveform.path.ecg", displayLabel: "Wahoo Heart Rate Monitor")),
        (["garmin hrm", "garmin hr"],
         .init(deviceType: "ecg_monitor", icon: "waveform.path.ecg", displayLabel: "Garmin Heart Rate Monitor")),
        (["coros"],
         .init(deviceType: "ecg_monitor", icon: "waveform.path.ecg", displayLabel: "COROS Heart Rate Monitor")),
        (["coospo"],
         .init(deviceType: "ecg_monitor", icon: "waveform.path.ecg", displayLabel: "CooSpo Heart Rate Monitor")),
        (["cycplus"],
         .init(deviceType: "ecg_monitor", icon: "waveform.path.ecg", displayLabel: "CYCPLUS Heart Rate Monitor")),

        // ── Blood pressure monitors ──────────────────────────────────────
        (["omron"],
         .init(deviceType: "bp_monitor", icon: "heart.circle.fill", displayLabel: "Omron Blood Pressure Monitor")),
        (["withings bpm", "withings bp", "withings core"],
         .init(deviceType: "bp_monitor", icon: "heart.circle.fill", displayLabel: "Withings Blood Pressure Monitor")),

        // ── Pulse oximeters ───────────────────────────────────────────────
        (["masimo"],
         .init(deviceType: "pulse_oximeter", icon: "lungs.fill", displayLabel: "Masimo Pulse Oximeter")),
        (["wellue", "viatom", "checkme"],
         .init(deviceType: "pulse_oximeter", icon: "lungs.fill", displayLabel: "Wellue/Viatom Pulse Oximeter")),

        // ── Wearables handled via their own dedicated integration
        // (HealthKit / Fitbit Web API), not raw BLE GATT — listed here so
        // the same lookup helper covers all sources for a unified icon set
        // if a raw peripheral with one of these names is ever seen during
        // a broad (non-restricted) scan.
        (["apple watch"],
         .init(deviceType: "activity_tracker", icon: "applewatch", displayLabel: "Apple Watch")),
        (["fitbit"],
         .init(deviceType: "activity_tracker", icon: "figure.walk.circle", displayLabel: "Fitbit")),
    ]

    /// Returns a known-device match for the given advertised BLE name, or
    /// nil if nothing in the catalog matches (caller should fall back to
    /// generic keyword-based inference).
    static func match(name: String) -> KnownBLEDeviceMatch? {
        let lowered = name.lowercased()
        for entry in catalog {
            if entry.matchers.contains(where: { lowered.contains($0) }) {
                return entry.match
            }
        }
        return nil
    }
}
