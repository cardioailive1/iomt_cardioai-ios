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

    enum CodingKeys: String, CodingKey {
        case id              = "alert_id"
        case patientID       = "patient_id"
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

    enum CodingKeys: String, CodingKey {
        case id         = "device_id"
        case patientID  = "patient_id"
        case isActive   = "is_active"
        case dataCount  = "data_count"
        case lastDataAt = "last_data_at"
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
    let bridgeID:        String
    let timestamp:       String
    let queueDepth:      Int
    let agentCount:      Int
    let messageBusTotal: Int
    let devices:         DeviceSummary

    enum CodingKeys: String, CodingKey {
        case bridgeID        = "bridge_id"
        case timestamp
        case queueDepth      = "queue_depth"
        case agentCount      = "agent_count"
        case messageBusTotal = "message_bus_total"
        case devices
    }
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
        case id          = "report_id"
        case alertID     = "alert_id"
        case patientID   = "patient_id"
        case level
        case summary
        case actions
        case notified
        case generatedAt = "generated_at"
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
}
