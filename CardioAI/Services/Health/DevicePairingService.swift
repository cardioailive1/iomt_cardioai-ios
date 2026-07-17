// DevicePairingService.swift
// Manages Bluetooth scanning, pairing, and real-time data streaming
// from the patient's IoMT wearable device into the CardioAI backend.
//
// Flow
// ────
//  1. Patient opens Device Pairing screen
//  2. App scans for BLE devices advertising the CardioAI service UUID
//  3. Patient selects their device from the list
//  4. App connects, negotiates BLE characteristics
//  5. On successful BLE connection:
//     a. App registers the device with the backend (POST /devices/register)
//     b. BLE data notifications start flowing
//     c. Each notification is pushed to the IoMT backend via the WebSocket
//        RPM_DATA channel — exactly mirroring what a real IoMT server sends
//  6. Device ID is saved to Keychain for auto-reconnect on future launches

import Foundation
import CoreBluetooth
import Combine
import WatchConnectivity

// MARK: - BLE Service / Characteristic UUIDs
// These must match the UUIDs advertised by your IoMT hardware devices.
// Update to match your specific device firmware.

enum CardioAIBLEService {
    static let primaryService    = CBUUID(string: "0000180D-0000-1000-8000-00805F9B34FB") // Heart Rate
    static let bloodPressure     = CBUUID(string: "00001810-0000-1000-8000-00805F9B34FB") // BP
    static let pulseOximeter     = CBUUID(string: "00001822-0000-1000-8000-00805F9B34FB") // SpO2
    static let healthThermometer = CBUUID(string: "00001809-0000-1000-8000-00805F9B34FB") // Temperature
    static let glucose           = CBUUID(string: "00001808-0000-1000-8000-00805F9B34FB") // Glucose meter
    static let weightScale       = CBUUID(string: "0000181D-0000-1000-8000-00805F9B34FB") // Weight scale
    static let bodyComposition   = CBUUID(string: "0000181B-0000-1000-8000-00805F9B34FB") // Body composition

    static let heartRateMeasurement = CBUUID(string: "00002A37-0000-1000-8000-00805F9B34FB")
    static let bloodPressureMeasurement = CBUUID(string: "00002A35-0000-1000-8000-00805F9B34FB")
    static let spo2Measurement      = CBUUID(string: "00002A5F-0000-1000-8000-00805F9B34FB")

    /// Standard BLE health/medical GATT services the scan surfaces to the
    /// patient. Anything not advertising one of these is filtered out so the
    /// device list isn't cluttered with AirPods, speakers, phones, etc.
    static let allHealthServices: [CBUUID] = [
        primaryService,
        bloodPressure,
        pulseOximeter,
        healthThermometer,
        glucose,
        weightScale,
        bodyComposition,
    ]
}

// MARK: - Pairing State

enum PairingState: Equatable {
    case idle
    case scanning
    case discovered([DiscoveredDevice])
    case connecting(DiscoveredDevice)
    case connected(DiscoveredDevice)
    case syncing(DiscoveredDevice)
    case failed(String)
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id:         UUID    // CBPeripheral.identifier
    let name:       String
    let rssi:       Int     // signal strength
    let peripheral: CBPeripheral

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Device Pairing Service

@MainActor
final class DevicePairingService: NSObject, ObservableObject {

    // ── Published state ────────────────────────────────────────────────────
    @Published private(set) var pairingState:     PairingState = .idle
    @Published private(set) var pairedDeviceID:   String?      = nil
    @Published private(set) var pairedDeviceName: String?      = nil
    @Published private(set) var isStreaming:      Bool         = false
    @Published private(set) var lastReading:      DeviceReading? = nil
    @Published private(set) var framesSynced:     Int           = 0

    // Apple Watch / Fitbit are separate, simpler connection states from
    // the BLE scan/discover/connect flow above — there's no nearby-device
    // list, just "authorize and start receiving data." Kept as their own
    // published properties rather than overloading PairingState, which
    // models BLE-specific states (scanning, discovered devices, RSSI, etc.)
    // that don't apply here.
    @Published private(set) var appleWatchConnected: Bool = false
    @Published private(set) var fitbitConnected:     Bool = false
    @Published private(set) var fitbitError:         String?

    // Real Apple Watch pairing state, from WatchConnectivity (the only
    // supported way to ask "is a watch paired to this iPhone?"). Name comes
    // from HealthKit heart-rate sources once the watch has written samples.
    @Published private(set) var watchPairingChecked = false
    @Published private(set) var isWatchPaired       = false
    @Published private(set) var watchName: String?  = nil

    // UserDefaults, deliberately NOT Keychain — Keychain survives app
    // reinstall, which is exactly how the stale "Connected" bug happened.
    private static let watchConnectedKey  = "apple_watch_user_connected"
    private static let healthStreamOffKey = "healthkit_stream_disabled"

    // Which source currently owns the displayed vitals. Rule: a connected BLE
    // wearable takes priority; otherwise HealthKit is the ambient default.
    // Only samples from the active source are pushed downstream, so the
    // dashboard never mixes a watch and a chest strap at the same time.
    enum VitalsSource { case none, healthKit, ble, fitbit }
    @Published private(set) var activeVitalsSource: VitalsSource = .none

    /// True while HealthKit heart-rate observation is running. Distinct from
    /// authorization: the user can disconnect Apple Watch (stop observing) while
    /// Health access stays granted, so arbitration keys off this, not the
    /// authorization status.
    private var healthKitObserving = false

    /// Human-readable name of the active source, for the dashboard indicator.
    var activeVitalsSourceLabel: String {
        switch activeVitalsSource {
        case .ble:       return connectedPeripheral?.name ?? pairedDeviceName ?? "Bluetooth device"
        case .healthKit: return "Apple Health"
        case .fitbit:    return "Fitbit"
        case .none:      return "No source"
        }
    }

    // ── Streams ────────────────────────────────────────────────────────────
    let readingSubject = PassthroughSubject<DeviceReading, Never>()

    // ── Dependencies ───────────────────────────────────────────────────────
    private let keychainService: KeychainService
    private let bridgeClient:    BridgeClient
    private let apiClient:       APIClient
    private let healthKitService: HealthKitService
    private let fitbitService:    GoogleHealthService

    // ── BLE internals ──────────────────────────────────────────────────────
    // Minimum signal strength (dBm) to surface a device. RSSI is negative:
    // closer to 0 = stronger. Rough bar mapping:
    //   > -60  ≈ 4 bars, -60…-70 ≈ 3 bars, -70…-80 ≈ 2 bars, < -80 ≈ 1 bar.
    // -75 hides the weak 1–2 bar devices the patient can't reliably pair with.
    private let minSignalRSSI = -75

    private var centralManager:   CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var discoveredDevices:   [UUID: DiscoveredDevice] = [:]
    private var patientID:           String = ""

    // MARK: - Init

    init(
        keychainService: KeychainService,
        bridgeClient:    BridgeClient,
        apiClient:       APIClient,
        healthKitService: HealthKitService,
        fitbitService:    GoogleHealthService
    ) {
        self.keychainService  = keychainService
        self.bridgeClient     = bridgeClient
        self.apiClient        = apiClient
        self.healthKitService = healthKitService
        self.fitbitService    = fitbitService
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        patientID      = (try? keychainService.read(.patientID)) ?? ""

        // Restore previously paired device
        pairedDeviceID   = try? keychainService.read(.deviceID)
        pairedDeviceName = pairedDeviceID.map { "Device \($0.prefix(8))" }

        // "Connected" requires the user to have explicitly tapped Connect in
        // THIS installation — a stored Keychain device ID alone is not proof
        // (it survives reinstalls, and the ambient HealthKit path also creates
        // one). WCSession activation below additionally clears this if no
        // watch is actually paired to the phone.
        appleWatchConnected = UserDefaults.standard.bool(forKey: Self.watchConnectedKey)
                              && healthKitService.authorizationRequested
        fitbitConnected     = keychainService.exists(.fitbitAccessToken)

        // Ambient default: if Health access was requested in a previous
        // session (and the user hasn't explicitly disconnected), resume
        // HealthKit observation on launch without prompting. A BLE wearable,
        // once connected, will suppress these samples (see recomputeSource).
        if healthKitService.authorizationRequested,
           !UserDefaults.standard.bool(forKey: Self.healthStreamOffKey) {
            startHealthKitObservation()
        }
        recomputeSource()
        startWatchDetection()
    }

    // MARK: - Vitals source arbitration

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

    /// Start observing HealthKit heart rate. Shared by the ambient-launch path
    /// and the explicit "Connect Apple Watch" flow. The callback only pushes
    /// while HealthKit is the active source, so a connected BLE wearable
    /// silently overrides the watch.
    private func startHealthKitObservation() {
        guard healthKitService.authorizationRequested else { return }

        let deviceID: String
        if let existing = try? keychainService.read(.appleWatchDeviceID) {
            deviceID = existing
        } else {
            deviceID = "apple-watch-\(UUID().uuidString)"
            try? keychainService.save(deviceID, for: .appleWatchDeviceID)
        }

        healthKitObserving = true
        healthKitService.startObservingHeartRate { [weak self] bpm, _, date in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeVitalsSource == .healthKit else { return }  // BLE owns the stream
                let reading = DeviceReading(
                    deviceID:    deviceID,
                    deviceType:  "activity_tracker",
                    vitals:      ["heart_rate": bpm],
                    qualityScore: 0.9,
                    timestamp:   date
                )
                self.pushReadingToBackend(reading)
            }
        }
    }

    /// Ask for HealthKit access once, right after login. First run shows the
    /// system permission sheet; later runs just make sure the ambient
    /// HealthKit stream is running (unless the user explicitly disconnected).
    func requestHealthAccessAfterLogin() async {
        if !healthKitService.authorizationRequested {
            await healthKitService.requestAuthorization()
        }
        if !UserDefaults.standard.bool(forKey: Self.healthStreamOffKey),
           !healthKitObserving {
            startHealthKitObservation()
            recomputeSource()
        }
    }

    // MARK: - Apple Watch detection (WatchConnectivity)
    //
    // Apple Watch never shows up in a CoreBluetooth scan — it pairs to the
    // iPhone over Apple's private protocol and doesn't advertise GATT health
    // services to third-party apps. WCSession is the only supported way to
    // ask "is a watch paired to this phone?", and HealthKit sample sources
    // are the only way to learn its name.

    func startWatchDetection() {
        guard WCSession.isSupported() else {
            watchPairingChecked = true
            isWatchPaired       = false
            return
        }
        let session = WCSession.default
        session.delegate = self
        if session.activationState == .activated {
            updateWatchPairing(from: session)
        } else {
            session.activate()   // result arrives in activationDidCompleteWith
        }
    }

    private func updateWatchPairing(from session: WCSession) {
        isWatchPaired       = session.isPaired
        watchPairingChecked = true
        if session.isPaired {
            Task { self.watchName = await self.healthKitService.fetchWatchSourceName() }
        } else {
            // No watch on this phone — never show "Connected".
            appleWatchConnected = false
            UserDefaults.standard.set(false, forKey: Self.watchConnectedKey)
        }
    }

    // MARK: - Scanning

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            pairingState = .failed("Bluetooth is not enabled. Please turn on Bluetooth in Settings.")
            return
        }
        discoveredDevices = [:]
        pairingState = .scanning

        // Scan is restricted to the standard health/medical GATT services
        // (see CardioAIBLEService.allHealthServices). This surfaces only
        // compliant health devices — heart rate monitors, BP cuffs, pulse
        // oximeters, thermometers, glucometers, scales — and keeps the
        // patient's list free of AirPods, speakers, phones and other nearby
        // BLE clutter. It's also faster than an unfiltered scan.
        //
        // TESTING WITHOUT REAL HARDWARE: temporarily set this to `nil` to
        // discover ANY nearby BLE peripheral for validating the scan → list
        // → connect UI flow. Connecting to a non-compliant device (AirPods,
        // a BLE speaker) succeeds at the CoreBluetooth level but produces no
        // readings — parseCharacteristic() only understands the standard
        // Heart Rate/BP/SpO2 characteristic UUIDs, so `didUpdateValueFor`
        // never fires. Useful for confirming pairing mechanics, not vitals.
        centralManager.scanForPeripherals(
            withServices: CardioAIBLEService.allHealthServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        // Stop scanning after 15 seconds
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if case .scanning = pairingState { stopScanning() }
        }
    }

    func stopScanning() {
        centralManager.stopScan()
        if case .scanning = pairingState {
            pairingState = discoveredDevices.isEmpty
                ? .idle
                : .discovered(Array(discoveredDevices.values)
                    .sorted { $0.rssi > $1.rssi })
        }
    }

    // MARK: - Connect

    func connect(to device: DiscoveredDevice) {
        pairingState = .connecting(device)
        centralManager.stopScan()
        centralManager.connect(device.peripheral, options: nil)
    }

    // MARK: - Disconnect

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        isStreaming       = false
        connectedPeripheral = nil
        pairingState        = .idle
        recomputeSource()  // BLE gone — fall back to HealthKit (if observing) or none
    }

    // MARK: - Apple Watch (via HealthKit)
    //
    // Unlike BLE, there's no "scan and pick a device" step — Apple Watch
    // heart rate data lives in HealthKit once the user grants read access.
    // This registers a stable pseudo-device (device_type: "activity_tracker")
    // with the backend and starts streaming every new HealthKit heart rate
    // sample through the exact same pushReadingToBackend() pipeline BLE
    // devices use, so it flows through the 7-agent clinical pipeline
    // identically regardless of source.

    func connectAppleWatch() async {
        guard isWatchPaired else {
            pairingState = .failed("No Apple Watch is paired with this iPhone. Pair one in the Watch app first.")
            return
        }
        // Apple Watch (HealthKit) becomes the sole active source.
        disconnect()          // drop any BLE wearable
        deactivateFitbit()    // pause Fitbit (keep token)
        await healthKitService.requestAuthorization()

        // Stable per-installation pseudo-device ID, generated once and
        // reused across app launches so the backend sees one consistent
        // device rather than a new registration every time.
        let deviceID: String
        if let existing = try? keychainService.read(.appleWatchDeviceID) {
            deviceID = existing
        } else {
            deviceID = "apple-watch-\(UUID().uuidString)"
            try? keychainService.save(deviceID, for: .appleWatchDeviceID)
        }

        await registerDeviceWithBackend(
            deviceID:   deviceID,
            deviceType: "activity_tracker",
            deviceName: "Apple Watch"
        )

        appleWatchConnected = true
        UserDefaults.standard.set(true,  forKey: Self.watchConnectedKey)
        UserDefaults.standard.set(false, forKey: Self.healthStreamOffKey)

        startHealthKitObservation()
        recomputeSource()  // now that Health is authorized, HealthKit may become active
    }

    func disconnectAppleWatch() {
        healthKitService.stopObservingHeartRate()
        healthKitObserving = false
        // Explicit opt-out: don't resurrect the HealthKit stream on next
        // launch (see init). Cleared again when the user reconnects.
        UserDefaults.standard.set(false, forKey: Self.watchConnectedKey)
        UserDefaults.standard.set(true,  forKey: Self.healthStreamOffKey)
        try? keychainService.delete(.appleWatchDeviceID)
        appleWatchConnected = false
        recomputeSource()  // fall back to BLE if connected, else none
    }

    // MARK: - Fitbit (via Google Health API)
    //
    // See GoogleHealthService.swift for why this looks different from BLE/Apple
    // Watch (cloud OAuth2 + polling rather than local streaming). Same
    // destination pipeline as everything else: pushReadingToBackend().

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

    /// Full user-initiated disconnect (the Disconnect button): stops polling,
    /// deletes the OAuth token, requires a fresh browser login to reconnect.
    func disconnectFitbit() {
        fitbitService.disconnect()  // stops polling + deletes tokens
        fitbitConnected = false
        recomputeSource()  // fall back to BLE / ambient HealthKit / none
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

    // MARK: - Register device with backend

    private func registerDeviceWithBackend(
        deviceID:   String,
        deviceType: String,
        deviceName: String
    ) async {
        do {
            try await apiClient.registerDevice(
                deviceID:   deviceID,
                deviceType: deviceType,
                patientID:  patientID,
                deviceName: deviceName
            )
            try? keychainService.save(deviceID, for: .deviceID)
            pairedDeviceID   = deviceID
            pairedDeviceName = deviceName
            logger_ios.info("[BLE] device registered with backend: \(deviceID)")
        } catch {
            logger_ios.warning("[BLE] backend registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Push reading to IoMT backend via WebSocket

    private func pushReadingToBackend(_ reading: DeviceReading) {
        lastReading  = reading
        framesSynced += 1
        readingSubject.send(reading)

        // Forward to BridgeClient as an RPM frame — same format the backend expects
        let frame: [String: Any] = [
            "device_id":    reading.deviceID,
            "patient_id":   patientID,
            "device_type":  reading.deviceType,
            "timestamp":    ISO8601DateFormatter().string(from: reading.timestamp),
            "quality_score": reading.qualityScore,
            "data":          reading.vitals,
        ]
        // Inject via BridgeClient's RPM data subject so it flows through
        // the same 7-agent pipeline as hardware IoMT devices
        bridgeClient.injectLocalFrame(frame)
    }
}

// MARK: - CBCentralManagerDelegate

extension DevicePairingService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state != .poweredOn {
                self.pairingState = .failed("Bluetooth unavailable: \(central.state.description)")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        Task { @MainActor in
            // Drop weak-signal devices (1–2 bars). RSSI of 127 means "not
            // available" from CoreBluetooth — treat that as unusable too.
            guard rssi >= self.minSignalRSSI, rssi != 127 else { return }

            let name   = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown Device"
            let device = DiscoveredDevice(id: peripheral.identifier,
                                         name: name,
                                         rssi: rssi,
                                         peripheral: peripheral)
            self.discoveredDevices[peripheral.identifier] = device
            self.pairingState = .discovered(
                Array(self.discoveredDevices.values).sorted { $0.rssi > $1.rssi }
            )
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        Task { @MainActor in
            self.deactivateFitbit()  // BLE wearable takes over — pause Fitbit (keep token)
            self.connectedPeripheral = peripheral
            self.recomputeSource()   // BLE now owns the vitals stream, overriding HealthKit
            peripheral.delegate      = self
            let device = self.discoveredDevices[peripheral.identifier]
                         ?? DiscoveredDevice(id: peripheral.identifier,
                                             name: peripheral.name ?? "Device",
                                             rssi: -60, peripheral: peripheral)
            self.pairingState = .connected(device)

            // Register device with backend
            let deviceID   = peripheral.identifier.uuidString
            let deviceType = self.inferDeviceType(from: peripheral)
            await self.registerDeviceWithBackend(
                deviceID:   deviceID,
                deviceType: deviceType,
                deviceName: device.name
            )

            // Discover BLE services
            peripheral.discoverServices([
                CardioAIBLEService.primaryService,
                CardioAIBLEService.bloodPressure,
                CardioAIBLEService.pulseOximeter,
            ])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.isStreaming         = false
            self.connectedPeripheral = nil
            self.pairingState        = .idle
            self.recomputeSource()   // BLE dropped — revert to HealthKit (if observing) or none
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.pairingState = .failed(error?.localizedDescription ?? "Failed to connect to device")
        }
    }

    private func inferDeviceType(from peripheral: CBPeripheral) -> String {
        let rawName = peripheral.name ?? ""
        if let known = KnownBLEDevices.match(name: rawName) {
            return known.deviceType
        }
        let name = rawName.lowercased()
        if name.contains("ecg") || name.contains("heart") { return "ecg_monitor" }
        if name.contains("bp") || name.contains("pressure") { return "bp_monitor" }
        if name.contains("spo") || name.contains("ox") { return "pulse_oximeter" }
        return "ecg_monitor"  // default
    }
}

// MARK: - CBPeripheralDelegate

extension DevicePairingService: CBPeripheralDelegate {

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard error == nil else { return }
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else { return }
        service.characteristics?.forEach { characteristic in
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        Task { @MainActor in
            if case .connected(let device) = self.pairingState {
                self.pairingState = .syncing(device)
                self.isStreaming  = true
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        Task { @MainActor in
            let reading = self.parseCharacteristic(
                characteristicUUID: characteristic.uuid,
                data:               data,
                deviceID:           peripheral.identifier.uuidString
            )
            if let reading {
                self.pushReadingToBackend(reading)
            }
        }
    }

    // MARK: - BLE Data Parsing

    private func parseCharacteristic(
        characteristicUUID: CBUUID,
        data:               Data,
        deviceID:           String
    ) -> DeviceReading? {
        switch characteristicUUID {

        case CardioAIBLEService.heartRateMeasurement:
            return parseHeartRate(data: data, deviceID: deviceID)

        case CardioAIBLEService.bloodPressureMeasurement:
            return parseBloodPressure(data: data, deviceID: deviceID)

        case CardioAIBLEService.spo2Measurement:
            return parseSpO2(data: data, deviceID: deviceID)

        default:
            return nil
        }
    }

    private func parseHeartRate(data: Data, deviceID: String) -> DeviceReading? {
        guard data.count >= 2 else { return nil }
        let flags  = data[0]
        let hr: Double = (flags & 0x01) == 0
            ? Double(data[1])                                      // 8-bit HR
            : Double(UInt16(data[1]) | (UInt16(data[2]) << 8))    // 16-bit HR
        return DeviceReading(
            deviceID:    deviceID,
            deviceType:  "ecg_monitor",
            vitals:      ["heart_rate": hr],
            qualityScore: 0.95,
            timestamp:   Date()
        )
    }

    private func parseBloodPressure(data: Data, deviceID: String) -> DeviceReading? {
        guard data.count >= 7 else { return nil }
        // IEEE 11073 SFLOAT encoding
        let systolic  = sfloat16(from: data, offset: 1)
        let diastolic = sfloat16(from: data, offset: 3)
        guard systolic > 0, diastolic > 0 else { return nil }
        return DeviceReading(
            deviceID:    deviceID,
            deviceType:  "bp_monitor",
            vitals:      ["systolic": systolic, "diastolic": diastolic],
            qualityScore: 0.97,
            timestamp:   Date()
        )
    }

    private func parseSpO2(data: Data, deviceID: String) -> DeviceReading? {
        guard data.count >= 3 else { return nil }
        let spo2 = Double(data[1])
        guard spo2 > 50 else { return nil }
        return DeviceReading(
            deviceID:    deviceID,
            deviceType:  "pulse_oximeter",
            vitals:      ["spo2": spo2],
            qualityScore: 0.96,
            timestamp:   Date()
        )
    }

    private func sfloat16(from data: Data, offset: Int) -> Double {
        guard data.count > offset + 1 else { return 0 }
        let raw   = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        let mant  = Int16(bitPattern: raw & 0x0FFF)
        let exp   = Int(Int8(bitPattern: UInt8(raw >> 12)))
        return Double(mant) * pow(10.0, Double(exp))
    }
}

// MARK: - WCSessionDelegate

extension DevicePairingService: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.updateWatchPairing(from: session)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Fires after the user switches to a different watch — reactivate
        // to pick up the new one.
        session.activate()
    }
}

// MARK: - Device Reading

struct DeviceReading {
    let deviceID:     String
    let deviceType:   String
    let vitals:       [String: Double]
    let qualityScore: Double
    let timestamp:    Date
}

// MARK: - CBManagerState description

extension CBManagerState {
    var description: String {
        switch self {
        case .poweredOff:   return "Bluetooth is turned off"
        case .poweredOn:    return "Bluetooth is on"
        case .unauthorized: return "Bluetooth access denied — check Settings"
        case .unsupported:  return "Bluetooth not supported on this device"
        case .resetting:    return "Bluetooth is resetting"
        case .unknown:      return "Bluetooth state unknown"
        @unknown default:   return "Unknown state"
        }
    }
}

// App-scoped logger (avoids import os everywhere)
import os.log
let logger_ios = Logger(subsystem: "com.cardioai.iomt", category: "CardioAI")
