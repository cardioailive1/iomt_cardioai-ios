# Fitbit via Google Health API + Single Active Vitals Source — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unhide the Fitbit device option, back it with the Google Health cloud API instead of the sunsetting Fitbit Web API, and make BLE / Apple Watch / Fitbit mutually exclusive so only the latest-connected device streams vitals (Apple Health as ambient fallback).

**Architecture:** Drop-in service swap — `GoogleHealthService` replaces `FitbitService` behind the identical `connect()/isConnected/lastError/disconnect()/startPolling{sample.bpm,.timestamp}` surface and the same keychain keys. Vitals arbitration in `DevicePairingService` gains a `.fitbit` source with highest priority; each connect path tears down the other explicit sources, and each source callback pushes only when it owns the stream.

**Tech Stack:** Swift, SwiftUI, CoreBluetooth, HealthKit, AuthenticationServices (ASWebAuthenticationSession), Google Health API v4.

## Global Constraints

- OAuth client ID (verbatim): `875586651219-mluk6di2f06flcj0mrl92fv8r644050b.apps.googleusercontent.com`
- Redirect URI: `cardioai://google-health-callback` — `cardioai` scheme already in `Info.plist`; do NOT modify Info.plist.
- Keychain keys reused unchanged: `.fitbitAccessToken`, `.fitbitRefreshToken`, `.fitbitDeviceID`.
- Backend device_type for Fitbit stays `activity_tracker`.
- No unit-test target changes; iOS build is the verification gate. Build command used throughout:
  ```bash
  xcodebuild -project CardioAI.xcodeproj -scheme CardioAI -sdk iphonesimulator \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    build CODE_SIGNING_ALLOWED=NO
  ```
- After code changes land, run `graphify update .` (AST-only, no API cost) per CLAUDE.md.

---

### Task 1: Swap FitbitService → GoogleHealthService (service wiring, build green)

**Files:**
- Create: `CardioAI/Services/Health/GoogleHealthService.swift` (copy from `googlehealthkitsfile/GoogleHealthService.swift`, then set real clientID)
- Delete: `CardioAI/Services/Health/FitbitService.swift`
- Modify: `CardioAI.xcodeproj/project.pbxproj` (4 refs)
- Modify: `CardioAI/Core/DependencyContainer.swift:30,44`
- Modify: `CardioAI/Services/Health/DevicePairingService.swift:90,105` (type decl + init param)
- Modify: `CardioAI/UI/Dashboard/DashboardView.swift:967` (preview init)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `GoogleHealthService` type in the graph with `connect() async`, `var isConnected: Bool`, `var lastError: String?`, `disconnect()`, `startPolling(onSample: ((GoogleHealthReading) -> Void)?)`, `stopPolling()`. `GoogleHealthReading` has `let bpm: Double`, `let timestamp: Date`. `DevicePairingService.init(...)` now takes `fitbitService: GoogleHealthService`.

- [ ] **Step 1: Copy the service file into the project source tree**

```bash
cp "googlehealthkitsfile/GoogleHealthService.swift" \
   "CardioAI/Services/Health/GoogleHealthService.swift"
```

- [ ] **Step 2: Set the real OAuth client ID**

In `CardioAI/Services/Health/GoogleHealthService.swift`, replace the placeholder:

```swift
    private let clientID    = "YOUR_GOOGLE_OAUTH_CLIENT_ID"
```

with:

```swift
    private let clientID    = "875586651219-mluk6di2f06flcj0mrl92fv8r644050b.apps.googleusercontent.com"
```

- [ ] **Step 3: Delete the legacy service**

```bash
git rm "CardioAI/Services/Health/FitbitService.swift"
```

(Deleting also removes its file-private `Data.base64URLEncodedString()` extension, avoiding any duplicate-symbol clash with the identical private extension in `GoogleHealthService.swift`.)

- [ ] **Step 4: Repoint the Xcode file reference (keep same build UUIDs, membership preserved)**

In `CardioAI.xcodeproj/project.pbxproj`, replace all four occurrences of `FitbitService.swift` with `GoogleHealthService.swift`:

```bash
sed -i '' 's#Health/FitbitService.swift#Health/GoogleHealthService.swift#g' \
  CardioAI.xcodeproj/project.pbxproj
```

Verify exactly 4 lines now reference the new name (build file, file reference, group child, sources build phase):

```bash
grep -c "GoogleHealthService.swift" CardioAI.xcodeproj/project.pbxproj
```
Expected: `4`

- [ ] **Step 5: Update DependencyContainer type + init**

In `CardioAI/Core/DependencyContainer.swift`, change the property declaration:

```swift
    let fitbitService:       FitbitService
```
to
```swift
    let fitbitService:       GoogleHealthService
```

and the initializer line:

```swift
        fitbitService        = FitbitService(keychainService: keychainService)
```
to
```swift
        fitbitService        = GoogleHealthService(keychainService: keychainService)
```

- [ ] **Step 6: Update DevicePairingService stored property + init parameter type**

In `CardioAI/Services/Health/DevicePairingService.swift`, change the stored property (near line 90):

```swift
    private let fitbitService:    FitbitService
```
to
```swift
    private let fitbitService:    GoogleHealthService
```

and the initializer parameter (near line 105):

```swift
        fitbitService:    FitbitService
```
to
```swift
        fitbitService:    GoogleHealthService
```

- [ ] **Step 7: Update the DashboardView SwiftUI preview**

In `CardioAI/UI/Dashboard/DashboardView.swift:967`, change `fitbitService: FitbitService(keychainService: KeychainService())` to `fitbitService: GoogleHealthService(keychainService: KeychainService())`. Full line becomes:

```swift
        .environmentObject(DevicePairingService(keychainService: KeychainService(), bridgeClient: BridgeClient(keychainService: KeychainService()), apiClient: APIClient(keychainService: KeychainService()), healthKitService: HealthKitService(), fitbitService: GoogleHealthService(keychainService: KeychainService())))
```

- [ ] **Step 8: Confirm no stale references remain**

```bash
grep -rn "FitbitService" CardioAI/ CardioAI.xcodeproj/project.pbxproj
```
Expected: no output (empty). `fitbitService` (lowercase property) and keychain `fitbit*` keys are expected to remain and are fine.

- [ ] **Step 9: Build**

Run the Global-Constraints build command.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: replace FitbitService with GoogleHealthService (Google Health cloud API)"
```

---

### Task 2: Single active vitals source (BLE / Apple Watch / Fitbit mutually exclusive)

**Files:**
- Modify: `CardioAI/Services/Health/DevicePairingService.swift` — `VitalsSource` enum (line ~116), `activeVitalsSourceLabel` (~126), `recomputeSource()` (~203), `connectFitbit()` / `disconnectFitbit()` (~422-462), BLE `didConnect` (~544), `connectAppleWatch()` (~369)

**Interfaces:**
- Consumes: `GoogleHealthService` (Task 1), existing `disconnect()` (BLE teardown, line 349), `recomputeSource()`, `fitbitService.stopPolling()`, `fitbitService.isConnected`.
- Produces: `enum VitalsSource { case none, healthKit, ble, fitbit }`; private `deactivateFitbit()` (pause, keeps token); `fitbitConnected` gated so only the active source pushes.

- [ ] **Step 1: Add `.fitbit` to the source enum**

In `DevicePairingService.swift:116`, change:

```swift
    enum VitalsSource { case none, healthKit, ble }
```
to
```swift
    enum VitalsSource { case none, healthKit, ble, fitbit }
```

- [ ] **Step 2: Add the Fitbit label case**

In `activeVitalsSourceLabel` (line ~126), add a `.fitbit` case so the switch stays exhaustive:

```swift
    var activeVitalsSourceLabel: String {
        switch activeVitalsSource {
        case .ble:       return connectedPeripheral?.name ?? pairedDeviceName ?? "Bluetooth device"
        case .healthKit: return "Apple Health"
        case .fitbit:    return "Fitbit"
        case .none:      return "No source"
        }
    }
```

- [ ] **Step 3: Give Fitbit top priority in arbitration**

Replace `recomputeSource()` (lines ~203-211) with:

```swift
    /// Recompute which source owns the vitals stream. Priority:
    /// Fitbit (explicit cloud) > BLE wearable > ambient HealthKit > none.
    /// Only one explicit device (BLE/Fitbit/Watch) is ever connected at a
    /// time — each connect path tears the others down first — so at most one
    /// of fitbit/ble is set here. HealthKit remains the ambient fallback.
    private func recomputeSource() {
        if fitbitConnected {
            activeVitalsSource = .fitbit
        } else if connectedPeripheral != nil {
            activeVitalsSource = .ble
        } else if healthKitObserving {
            activeVitalsSource = .healthKit
        } else {
            activeVitalsSource = .none
        }
    }
```

- [ ] **Step 4: Rewrite `connectFitbit()` to evict other sources, gate pushes, and support instant reconnect**

Replace the whole `connectFitbit()` body (lines ~422-462) with:

```swift
    func connectFitbit() async {
        // Fitbit becomes the sole active source: tear down any BLE wearable.
        // Ambient HealthKit keeps observing but is gated off below (it only
        // pushes when activeVitalsSource == .healthKit), so it silently
        // resumes as the fallback once Fitbit disconnects.
        disconnect()  // cancels BLE peripheral if connected (no-op otherwise)

        // Instant reconnect: skip the browser OAuth round-trip if a valid
        // token is already in the keychain (e.g. we only paused Fitbit when
        // switching to another device earlier this session).
        if !fitbitService.isConnected {
            await fitbitService.connect()
            guard fitbitService.isConnected else {
                fitbitError = fitbitService.lastError
                return
            }
        }

        let deviceID: String
        if let existing = try? keychainService.read(.fitbitDeviceID) {
            deviceID = existing
        } else {
            deviceID = "fitbit-\(UUID().uuidString)"
            try? keychainService.save(deviceID, for: .fitbitDeviceID)
        }

        await registerDeviceWithBackend(
            deviceID:   deviceID,
            deviceType: "activity_tracker",
            deviceName: "Fitbit"
        )

        fitbitConnected = true
        fitbitError     = nil
        recomputeSource()  // Fitbit now owns the stream

        fitbitService.startPolling { [weak self] sample in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeVitalsSource == .fitbit else { return }  // another source took over
                let reading = DeviceReading(
                    deviceID:    deviceID,
                    deviceType:  "activity_tracker",
                    vitals:      ["heart_rate": sample.bpm],
                    qualityScore: 0.85,  // polled, not real-time — slightly lower confidence
                    timestamp:   sample.timestamp
                )
                self.pushReadingToBackend(reading)
            }
        }
    }
```

- [ ] **Step 5: Add a token-preserving pause and update the full disconnect**

Replace `disconnectFitbit()` (lines ~460-463) with both methods:

```swift
    /// Full user-initiated disconnect (the Disconnect button): stops polling,
    /// deletes the OAuth token, requires a fresh browser login to reconnect.
    func disconnectFitbit() {
        fitbitService.disconnect()  // stops polling + deletes tokens
        fitbitConnected = false
        recomputeSource()  // fall back to BLE (none here) / ambient HealthKit / none
    }

    /// Silent eviction used when another device is connected: stops the
    /// Fitbit stream and flips the UI to disconnected, but KEEPS the OAuth
    /// token so reconnecting is instant (see connectFitbit's isConnected
    /// short-circuit).
    private func deactivateFitbit() {
        guard fitbitConnected else { return }
        fitbitService.stopPolling()
        fitbitConnected = false
        recomputeSource()
    }
```

- [ ] **Step 6: Evict Fitbit when a BLE device connects**

In the BLE `didConnect` handler (line ~548), add the eviction as the first line inside the `Task { @MainActor in` block, immediately before `self.connectedPeripheral = peripheral`:

```swift
        Task { @MainActor in
            self.deactivateFitbit()  // BLE wearable takes over — pause Fitbit (keep token)
            self.connectedPeripheral = peripheral
            self.recomputeSource()   // BLE now owns the vitals stream, overriding HealthKit
```

- [ ] **Step 7: Evict BLE + Fitbit when Apple Watch connects**

In `connectAppleWatch()` (line ~369), immediately after the `isWatchPaired` guard and before `await healthKitService.requestAuthorization()`, add:

```swift
        guard isWatchPaired else {
            pairingState = .failed("No Apple Watch is paired with this iPhone. Pair one in the Watch app first.")
            return
        }
        // Apple Watch (HealthKit) becomes the sole active source.
        disconnect()          // drop any BLE wearable
        deactivateFitbit()    // pause Fitbit (keep token)
        await healthKitService.requestAuthorization()
```

- [ ] **Step 8: Build**

Run the Global-Constraints build command.
Expected: `** BUILD SUCCEEDED **` (exhaustive-switch and type checks confirm the `.fitbit` case and new methods compile).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: single active vitals source — BLE/Watch/Fitbit mutually exclusive, HealthKit fallback"
```

---

### Task 3: Unhide the Fitbit option + verify end-to-end

**Files:**
- Modify: `CardioAI/UI/DevicePairing/DevicePairingView.swift:167`

**Interfaces:**
- Consumes: `pairingService.connectFitbit()`, `disconnectFitbit()`, `fitbitConnected`, `fitbitError` (already wired in the existing `ExternalSourcesSection`).
- Produces: visible Fitbit row in Device Pairing.

- [ ] **Step 1: Flip the feature flag**

In `CardioAI/UI/DevicePairing/DevicePairingView.swift:167`, change:

```swift
    private let fitbitEnabled = false
```
to
```swift
    private let fitbitEnabled = true
```

- [ ] **Step 2: Build**

Run the Global-Constraints build command.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Refresh the knowledge graph**

```bash
graphify update .
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: unhide Fitbit device option (Google Health-backed)"
```

- [ ] **Step 5: Manual verification (simulator/device, requires the Google test-user account)**

Run the app and confirm, in order:
1. Device Pairing screen shows the **Fitbit** row (no longer hidden).
2. Tap **Connect** → Google OAuth sheet appears → sign in with a registered test-user Google account → sheet dismisses, row shows "Connected · syncing heart rate".
3. Within ~5 min a heart-rate reading reaches the backend/dashboard, dashboard source indicator reads **Fitbit**.
4. With Fitbit active, connect a BLE device → Fitbit row flips to disconnected, dashboard source becomes the BLE device.
5. Reconnect Fitbit → no browser prompt (instant, token reused); it becomes active again and evicts BLE.
6. Tap Fitbit **Disconnect** → source falls back to Apple Health if HealthKit is observing, else "No source".

Note: if `clientID` were still the placeholder, Connect would surface a "not configured yet" message instead of a crash — with the real ID set in Task 1 this path should not appear.

---

## Notes / follow-ups (out of plan scope)

- Production release to arbitrary patients requires Google's CASA restricted-scope security review; testing supports 100 test-user emails without it.
- Direct Fitbit BLE is intentionally excluded — Fitbit BLE is proprietary/encrypted and unreadable by third-party apps.
