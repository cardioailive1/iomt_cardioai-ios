// Models.swift
// Swift data models — mirror the Python dataclasses in
// iomt_cardioai_production.py.

import Foundation

// MARK: - Alert Level

enum AlertLevel: String, Codable, CaseIterable {
    case critical = "critical"
    case high     = "high"
    case medium   = "medium"
    case low      = "low"

    var displayName: String {
        rawValue.capitalized
    }

    var systemImageName: String {
        switch self {
        case .critical: return "heart.fill"
        case .high:     return "exclamationmark.triangle.fill"
        case .medium:   return "exclamationmark.circle.fill"
        case .low:      return "info.circle.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .critical: return "#F44336"
        case .high:     return "#FF9800"
        case .medium:   return "#2196F3"
        case .low:      return "#4CAF50"
        }
    }
}

// MARK: - Device Type

enum DeviceType: String, Codable {
    case ecgMonitor        = "ecg_monitor"
    case bpMonitor         = "bp_monitor"
    case pulseOximeter     = "pulse_oximeter"
    case smartStethoscope  = "smart_stethoscope"
    case implantableMonitor = "implantable_monitor"
    case activityTracker   = "activity_tracker"
    case paceMaker         = "pace_maker"

    var displayName: String {
        switch self {
        case .ecgMonitor:         return "ECG Monitor"
        case .bpMonitor:          return "Blood Pressure Monitor"
        case .pulseOximeter:      return "Pulse Oximeter"
        case .smartStethoscope:   return "Smart Stethoscope"
        case .implantableMonitor: return "Implantable Monitor"
        case .activityTracker:    return "Activity Tracker"
        case .paceMaker:          return "Pacemaker"
        }
    }
}

// MARK: - RPM Alert

struct RPMAlert: Identifiable, Codable {
    let id:               String
    let patientID:        String
    let alertLevel:       AlertLevel
    let description:      String
    let requiredActions:  [String]
    let notifiedParties:  [String]
    let timestamp:        String

    var isCritical: Bool { alertLevel == .critical }

    // Keys post-`.convertFromSnakeCase`: snake_case JSON is already camelCased
    // by the decoder, so rawValues here must be the CONVERTED form.
    enum CodingKeys: String, CodingKey {
        case id              = "alertId"
        case patientID       = "patientId"
        case alertLevel      = "level"
        case description
        case requiredActions = "actions"
        case notifiedParties = "notified"
        case timestamp
    }
}

// MARK: - Device Info

struct DeviceInfo: Identifiable, Codable {
    let id:          String
    let patientID:   String
    let isActive:    Bool
    let dataCount:   Int
    let lastDataAt:  String?

    // rawValues in CONVERTED (camelCase) form — decoder applies
    // `.convertFromSnakeCase` before matching keys.
    enum CodingKeys: String, CodingKey {
        case id         = "deviceId"
        case patientID  = "patientId"
        case isActive
        case dataCount
        case lastDataAt
    }
}

// MARK: - Device Summary (from /devices)

struct DeviceSummary: Codable {
    let total:    Int
    let active:   Int
    let inactive: Int
    let devices:  [DeviceInfo]
}

// MARK: - Bridge Status (from /health)

struct BridgeStatus: Codable {
    let bridgeId:        String
    let timestamp:       String
    let queueDepth:      Int
    let agentCount:      Int
    let messageBusTotal: Int
    let devices:         DeviceSummary
    // Keys resolved by decoder's `.convertFromSnakeCase` strategy.
    // Do NOT add snake_case CodingKeys — that double-maps and breaks decode.
}

// MARK: - Clinical Report

struct ClinicalReport: Identifiable, Codable {
    let id:          String
    let alertID:     String
    let patientID:   String
    let level:       AlertLevel
    let summary:     String
    let actions:     [String]
    let notified:    [String]
    let generatedAt: String

    enum CodingKeys: String, CodingKey {
        // rawValues in CONVERTED (camelCase) form — see decoder strategy.
        case id          = "reportId"
        case alertID     = "alertId"
        case patientID   = "patientId"
        case level
        case summary
        case actions
        case notified
        case generatedAt

    }
}

// MARK: - RPM Frame (from WebSocket RPM_DATA)

struct RPMFrame {
    let deviceID:     String
    let patientID:    String
    let timestamp:    String
    let heartRate:    Double?
    let systolic:     Double?
    let diastolic:    Double?
    let spo2:         Double?
    let qualityScore: Double

    init(from dict: [String: Any]) {
        deviceID     = dict["device_id"]  as? String ?? ""
        patientID    = dict["patient_id"] as? String ?? ""
        timestamp    = dict["timestamp"]  as? String ?? ""
        qualityScore = dict["quality_score"] as? Double ?? 1.0
        let data     = dict["data"] as? [String: Any] ?? [:]
        heartRate    = data["heart_rate"]  as? Double
        systolic     = data["systolic"]    as? Double
        diastolic    = data["diastolic"]   as? Double
        spo2         = data["spo2"]        as? Double
    }

    /// Merge a new frame over a previous one, keeping the newest non-nil value
    /// per field. A source may report vitals in separate partial frames — BLE
    /// sends HR, BP, and SpO2 as distinct characteristic notifications, and the
    /// HealthKit/Fitbit paths likewise attach SpO2/BP alongside HR — so a
    /// partial frame must not blank the fields it doesn't carry.
    init(merging new: RPMFrame, over old: RPMFrame?) {
        deviceID     = new.deviceID.isEmpty  ? (old?.deviceID  ?? "") : new.deviceID
        patientID    = new.patientID.isEmpty ? (old?.patientID ?? "") : new.patientID
        timestamp    = new.timestamp
        heartRate    = new.heartRate ?? old?.heartRate
        systolic     = new.systolic  ?? old?.systolic
        diastolic    = new.diastolic ?? old?.diastolic
        spo2         = new.spo2       ?? old?.spo2
        qualityScore = new.qualityScore
    }
}
