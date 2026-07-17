# Fitbit via Google Health API + Single Active Vitals Source

Date: 2026-07-17
Status: Approved

## Summary

Two changes shipped together:

1. **Unhide Fitbit, migrate to Google Health cloud OAuth.** Replace the legacy
   `FitbitService` (Fitbit Web API — new-app registration closed, full shutoff
   Sept 2026) with `GoogleHealthService`, which pulls Fitbit heart rate through
   the Google Health API (`health.googleapis.com/v4`) using Google OAuth 2.0 +
   PKCE. The reference implementation was supplied in `googlehealthkitsfile/`.
2. **Single active vitals source across all device types.** BLE wearable, Apple
   Watch, and Fitbit become mutually exclusive: connecting one auto-disconnects
   the previously active device, and only the latest-connected device streams
   vitals. Apple Health (HealthKit) is the ambient default/fallback when no
   explicit device is connected.

Fitbit is **not** reachable over direct Bluetooth for third-party apps (its BLE
is proprietary/encrypted), so the cloud OAuth path is the only viable option.

## Why

- Legacy Fitbit Web API sunsets Sept 2026; new dev-portal registration is
  already closed. Google Health API is the sanctioned replacement.
- Today Fitbit polling pushes readings independently of the BLE/HealthKit
  arbitration, so the dashboard could mix sources. The product requires exactly
  one visible source at a time — the most recently connected device.

## Configuration prerequisite (user action, not code)

- Google Cloud Console: project created, Google Health API enabled, iOS OAuth
  client created (public client, PKCE, no secret).
- OAuth client ID:
  `875586651219-mluk6di2f06flcj0mrl92fv8r644050b.apps.googleusercontent.com`
  → set at `GoogleHealthService.swift` `clientID`.
- Redirect URI `cardioai://google-health-callback` — the `cardioai` URL scheme
  is already registered in `Info.plist`; no plist change needed.
- Production (arbitrary patients) requires Google's CASA restricted-scope
  security review. Testing supports up to 100 test-user emails without it.

## Component changes

| # | File | Change |
|---|------|--------|
| 1 | `CardioAI/Services/Health/GoogleHealthService.swift` | Add (from `googlehealthkitsfile/`), set real `clientID` |
| 2 | `CardioAI/Services/Health/FitbitService.swift` | Delete — dead after swap, reuses same keychain keys |
| 3 | `CardioAI/Core/DependencyContainer.swift` | Property + init: `FitbitService` → `GoogleHealthService` |
| 4 | `CardioAI/Services/Health/DevicePairingService.swift` | Type swap (2 lines) + arbitration edits (below) |
| 5 | `CardioAI/UI/Dashboard/DashboardView.swift` | Preview init type swap (line ~967) |
| 6 | `CardioAI/UI/DevicePairing/DevicePairingView.swift` | `fitbitEnabled = false` → `true` (line ~167) |
| 7 | `*.xcodeproj/project.pbxproj` | Swap 4 FitbitService refs → GoogleHealthService |
| 8 | `Info.plist` | No change (`cardioai` scheme already present) |

`GoogleHealthService` is a drop-in for the existing `connectFitbit()` /
`disconnectFitbit()` code: it exposes the same `connect()`, `isConnected`,
`lastError`, `disconnect()`, and `startPolling { sample.bpm, sample.timestamp }`
surface, and reuses the same keychain keys (`.fitbitAccessToken`,
`.fitbitRefreshToken`, `.fitbitDeviceID`).

## Single active source arbitration

Source model:

```swift
enum VitalsSource { case none, healthKit, ble, fitbit }
```

`recomputeSource()` priority (only one explicit device can be connected at a
time, so at most one of fitbit/ble is ever set):

```
fitbitConnected      -> .fitbit
connectedPeripheral  -> .ble
healthKitObserving   -> .healthKit   (ambient default / Apple Watch)
else                 -> .none
```

Mutual exclusion on connect (each new connect tears down the previous explicit
device before activating):

- **Connect Fitbit** — cancel the active BLE peripheral connection first, then
  activate Fitbit, then `recomputeSource()`.
- **Connect BLE** (in `didConnect`) — `disconnectFitbit()` first, then activate
  BLE, then `recomputeSource()`.
- **Connect Apple Watch** — cancel BLE + `disconnectFitbit()`, then start
  HealthKit observation, then `recomputeSource()`.

Push gating: every source callback pushes to the backend only when it owns the
stream. The Fitbit poll closure gains `guard activeVitalsSource == .fitbit`
(the BLE and HealthKit closures already gate the same way). This guarantees the
dashboard never mixes readings from two sources.

Disconnect semantics: switching away from Fitbit stops polling and sets
`fitbitConnected = false` (UI shows disconnected) but keeps the OAuth token in
keychain, so reconnecting is instant with no browser re-login. When the active
explicit device drops, vitals fall back to ambient Apple Health if HealthKit is
observing, otherwise `.none`.

## Data flow (unchanged pipeline)

Tap Connect (Fitbit) → `ASWebAuthenticationSession` Google OAuth + PKCE →
token saved to keychain → poll every 5 min → `GoogleHealthReading` →
`DeviceReading{ heart_rate }` → `pushReadingToBackend`. Identical downstream
path to BLE and HealthKit.

## Error handling

- Unconfigured `clientID` → `lastError` surfaces to `fitbitError`, shown in the
  Fitbit row; no crash.
- HTTP 401 on poll → refresh access token via refresh token, retry once.
- Refresh token expired/revoked → `disconnect()`, user must reconnect.
- Google Health API response shape drift → defensive parse; logs a warning and
  skips the sample rather than crashing.

## Testing

- Build clean after the type swaps and file add/delete.
- Tap Connect with the real `clientID` → Google OAuth sheet → grant → heart rate
  begins polling to the backend; Fitbit row shows "Connected".
- Connect a BLE device while Fitbit is active → Fitbit row flips to
  disconnected, BLE becomes the active source; and vice versa.
- Disconnect the active explicit device → vitals fall back to Apple Health.

## Out of scope

- Direct Fitbit BLE (not possible for third-party apps).
- Google CASA production review (compliance task, tracked separately).
- Backend changes (pipeline already accepts `activity_tracker` heart rate).
