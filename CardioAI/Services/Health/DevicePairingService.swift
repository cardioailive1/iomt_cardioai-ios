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

// MARK: - BLE Service / Characteristic UUIDs
// These must match the UUIDs advertised by your IoMT hardware devices.
// Update to match your specific device firmware.

enum CardioAIBLEService {
    static let primaryService    = CBUUID(string: "0000180D-0000-1000-8000-00805F9B34FB") // Heart Rate
    static let bloodPressure     = CBUUID(string: "00001810-0000-1000-8000-00805F9B34FB") // BP
    static let pulseOximeter     = CBUUID(string: "00001822-0000-1000-8000-00805F9B34FB") // SpO2

    static let heartRateMeasurement = CBUUID(string: "00002A37-0000-1000-8000-00805F9B34FB")
    static let bloodPressureMeasurement = CBUUID(string: "00002A35-0000-1000-8000-00805F9B34FB")
    static let spo2Measurement      = CBUUID(string: "00002A5F-0000-1000-8000-00805F9B34FB")
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

    // ── Streams ────────────────────────────────────────────────────────────
    let readingSubject = PassthroughSubject<DeviceReading, Never>()

    // ── Dependencies ───────────────────────────────────────────────────────
    private let keychainService: KeychainService
    private let bridgeClient:    BridgeClient
    private let apiClient:       APIClient

    // ── BLE internals ──────────────────────────────────────────────────────
    private var centralManager:   CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var discoveredDevices:   [UUID: DiscoveredDevice] = [:]
    private var patientID:           String = ""

    // MARK: - Init

    init(
        keychainService: KeychainService,
        bridgeClient:    BridgeClient,
        apiClient:       APIClient
    ) {
        self.keychainService = keychainService
        self.bridgeClient    = bridgeClient
        self.apiClient       = apiClient
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        patientID      = (try? keychainService.read(.patientID)) ?? ""

        // Restore previously paired device
        pairedDeviceID   = try? keychainService.read(.deviceID)
        pairedDeviceName = pairedDeviceID.map { "Device \($0.prefix(8))" }
    }

    // MARK: - Scanning

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            pairingState = .failed("Bluetooth is not enabled. Please turn on Bluetooth in Settings.")
            return
        }
        discoveredDevices = [:]
        pairingState = .scanning
        centralManager.scanForPeripherals(
            withServices: [
                CardioAIBLEService.primaryService,
                CardioAIBLEService.bloodPressure,
                CardioAIBLEService.pulseOximeter,
            ],
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
        Task { @MainActor in
            let name   = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown Device"
            let device = DiscoveredDevice(id: peripheral.identifier,
                                         name: name,
                                         rssi: RSSI.intValue,
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
            self.connectedPeripheral = peripheral
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
        let name = peripheral.name?.lowercased() ?? ""
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
