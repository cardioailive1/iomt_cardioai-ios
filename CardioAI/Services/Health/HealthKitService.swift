// HealthKitService.swift
// Writes RPM data back to Apple Health so the patient's GP can see it.

import Foundation
import HealthKit

final class HealthKitService {

    private let store = HKHealthStore()

    private let writeTypes: Set<HKSampleType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.bloodPressureSystolic),
        HKQuantityType(.bloodPressureDiastolic),
    ]

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: writeTypes, read: [])
    }

    func writeFrame(_ frame: RPMFrame) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var samples: [HKSample] = []
        let now = Date()

        if let hr = frame.heartRate {
            samples.append(HKQuantitySample(
                type:     HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: hr),
                start:    now, end: now
            ))
        }

        if let spo2 = frame.spo2 {
            samples.append(HKQuantitySample(
                type:     HKQuantityType(.oxygenSaturation),
                quantity: HKQuantity(unit: .percent(), doubleValue: spo2 / 100),
                start:    now, end: now
            ))
        }

        if let sys = frame.systolic, let dia = frame.diastolic {
            let systolicSample = HKQuantitySample(
                type:     HKQuantityType(.bloodPressureSystolic),
                quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: sys),
                start:    now, end: now
            )
            let diastolicSample = HKQuantitySample(
                type:     HKQuantityType(.bloodPressureDiastolic),
                quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: dia),
                start:    now, end: now
            )
            let correlation = HKCorrelation(
                type:    HKCorrelationType(.bloodPressure),
                start:   now, end: now,
                objects: [systolicSample, diastolicSample]
            )
            samples.append(correlation)
        }

        guard !samples.isEmpty else { return }
        try? await store.save(samples)
    }
}

// MARK: - Background Task Scheduler

import BackgroundTasks

final class BackgroundTaskScheduler {

    static let shared = BackgroundTaskScheduler()
    private let heartbeatTaskID = "com.cardioai.iomt.heartbeat"

    private init() { }

    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: heartbeatTaskID,
            using: nil
        ) { task in
            self.handleHeartbeatTask(task as! BGProcessingTask)
        }
    }

    func scheduleHeartbeatTask() {
        let request = BGProcessingTaskRequest(identifier: heartbeatTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower       = false
        request.earliestBeginDate           = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleHeartbeatTask(_ task: BGProcessingTask) {
        scheduleHeartbeatTask()  // reschedule

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Keep connection alive in the background for up to 30 seconds
        let deadline = DispatchTime.now() + 30
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            task.setTaskCompleted(success: true)
        }
    }
}

// MARK: - Color Extension

import SwiftUI

extension Color {
    init(hex: String) {
        let hex     = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            (r, g, b) = (Double((int >> 16) & 0xFF) / 255,
                         Double((int >> 8)  & 0xFF) / 255,
                         Double(int         & 0xFF) / 255)
        default:
            (r, g, b) = (1, 1, 1)
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - AppConfiguration helpers

extension AppConfiguration {
    var tokenTTLSeconds: Int {
        Int(token_ttl_seconds ?? 3600)
    }
}

private extension AppConfiguration {
    var token_ttl_seconds: Double? {
        Bundle.main.infoDictionary?["TOKEN_TTL_SECONDS"] as? Double
    }
}
