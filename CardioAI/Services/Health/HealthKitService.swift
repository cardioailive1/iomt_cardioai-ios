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

    // Read types for pulling Apple Watch (or any HealthKit-writing device,
    // e.g. Fitbit's own Health app integration) heart rate data INTO the
    // app, separate from writeTypes above which push CardioAI's own RPM
    // data OUT to Apple Health for the patient's GP to see.
    private let readTypes: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
    ]

    private var heartRateQuery: HKQuery?
    private var heartRateAnchor: HKQueryAnchor?

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: writeTypes, read: readTypes)
    }

    /// True if the user has actually granted read access to heart rate —
    /// requestAuthorization() can succeed at the OS level while the user
    /// still denies specific types, so check this before relying on data
    /// actually arriving.
    var isHeartRateReadAuthorized: Bool {
        store.authorizationStatus(for: HKQuantityType(.heartRate)) != .notDetermined
    }

    /// Starts observing new heart rate samples as Apple Watch (or any
    /// source writing to HealthKit) produces them. `onSample` is called
    /// with (bpm, sourceName, date) for every new sample, including an
    /// initial batch of recent samples when first called.
    ///
    /// Uses HKAnchoredObjectQuery (incremental, only NEW samples since the
    /// last anchor) wrapped in an HKObserverQuery so updates keep flowing
    /// even while the app is backgrounded, provided background delivery is
    /// enabled (see enableBackgroundDelivery below).
    func startObservingHeartRate(onSample: @escaping (Double, String, Date) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let heartRateType = HKQuantityType(.heartRate)

        let observer = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else {
                logger_ios.warning("[HealthKit] observer query error: \(error!.localizedDescription)")
                completionHandler()
                return
            }
            self?.fetchNewHeartRateSamples(onSample: onSample, completion: completionHandler)
        }
        store.execute(observer)
        heartRateQuery = observer

        store.enableBackgroundDelivery(for: heartRateType, frequency: .immediate) { success, error in
            if let error {
                logger_ios.warning("[HealthKit] background delivery enable failed: \(error.localizedDescription)")
            } else {
                logger_ios.info("[HealthKit] background delivery enabled=\(success)")
            }
        }

        // Fetch an initial batch immediately so the pairing screen shows
        // something right away rather than waiting for the next Watch
        // measurement (which can be minutes away).
        fetchNewHeartRateSamples(onSample: onSample, completion: {})
    }

    func stopObservingHeartRate() {
        if let heartRateQuery {
            store.stop(heartRateQuery)
        }
        heartRateQuery  = nil
        heartRateAnchor = nil
    }

    private func fetchNewHeartRateSamples(
        onSample: @escaping (Double, String, Date) -> Void,
        completion: @escaping () -> Void
    ) {
        let heartRateType = HKQuantityType(.heartRate)
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: nil,
            anchor: heartRateAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samplesOrNil, _, newAnchor, error in
            defer { completion() }
            guard error == nil, let samples = samplesOrNil as? [HKQuantitySample] else {
                if let error { logger_ios.warning("[HealthKit] anchored query error: \(error.localizedDescription)") }
                return
            }
            self?.heartRateAnchor = newAnchor
            for sample in samples {
                let bpm = sample.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
                let sourceName = sample.sourceRevision.source.name
                onSample(bpm, sourceName, sample.endDate)
            }
        }
        store.execute(query)
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
