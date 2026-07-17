# Vitals Source Arbitration — Design

Date: 2026-07-14

## Context

Originally scoped as "integrate Fitbit via Terra aggregator." Dropped after two
constraints surfaced: **no paid services** and **must survive past Sept 2026**
(Fitbit Web API third-party deprecation). No aggregator — free or paid — makes
Fitbit data immortal; they all wrap the same dying API.

Revised goal, in the user's words: *"default show vitals from HealthKit, but if
they connect a Bluetooth device, show the vitals from that wearable."*

This is a **source-arbitration** feature, not an aggregator integration. It is
frontend-only. No backend changes. Terra abandoned. Fitbit code left hidden
(`fitbitEnabled = false`), not deleted.

## Existing pipeline (unchanged)

Both HealthKit (Apple Watch) and BLE devices already push through the same path:
`pushReadingToBackend()` → `readingSubject` (+ WebSocket RPM frames) →
`DashboardViewModel.hrHistory` / `latestFrame`. The gap is that when both a watch
and a BLE device stream, readings interleave with no priority, and HealthKit only
starts on an explicit "Connect Apple Watch" tap (not a default).

## Arbitration rule

One active source at a time, BLE wins:

- `connectedPeripheral != nil` → source = **BLE**; HealthKit samples suppressed.
- else `isHeartRateReadAuthorized` → source = **HealthKit** (ambient default).
- else → **none**.

## Changes — `DevicePairingService.swift`

1. `enum VitalsSource { case none, healthKit, ble }` +
   `@Published private(set) var activeVitalsSource: VitalsSource = .none`.
2. `recomputeSource()` implementing the rule above. Called on: init, BLE
   `didConnect`, BLE `didDisconnectPeripheral`, BLE `disconnect()`,
   `connectAppleWatch()`.
3. `startHealthKitObservation()` helper — shared by the ambient-launch path and
   `connectAppleWatch()`. The observe callback gains
   `guard activeVitalsSource == .healthKit else { return }` so watch samples are
   dropped while a BLE device owns the stream.
4. **Ambient default:** init calls `startHealthKitObservation()` when Health is
   already authorized. **No permission prompt on launch** — authorization is only
   granted through the existing "Connect Apple Watch" flow.
5. BLE disconnect falls back to HealthKit automatically via `recomputeSource()`.

## Dashboard

Small source indicator in the existing status strip: "Apple Health" or the BLE
device name, driven by `activeVitalsSource`.

## Non-goals

- No backend work.
- No Fitbit deletion (kept hidden).
- No aggregator (Terra/Vital/Metriport) — documented as rejected given
  no-paid + post-Sept-2026 constraints. HealthKit is the durable free pillar;
  BLE wearables override when present.
