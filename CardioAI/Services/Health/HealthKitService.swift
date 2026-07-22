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
        // Extra vitals an Apple Watch / synced device may record. Pulled into
        // the vitals pipeline alongside heart rate when present.
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.bloodPressureSystolic),
        HKQuantityType(.bloodPressureDiastolic),
        // Fitness (read-only, informational — Activity section / Fitness view).
        // Unlike heart rate, these do NOT flow through the clinical AI pipeline
        // or reach the care team — wellness context only.
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        HKObjectType.workoutType(),
    ]

    private var heartRateQuery: HKQuery?
    private var heartRateAnchor: HKQueryAnchor?

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        UserDefaults.standard.set(true, forKey: Self.authRequestedKey)
    }

    /// True once the system permission sheet has been shown. iOS deliberately
    /// never reveals whether READ access was granted — authorizationStatus(for:)
    /// only reports WRITE permission — so "we asked" is the only honest signal.
    /// If the user denied reads, queries simply return no samples.
    private static let authRequestedKey = "healthkit_auth_requested"
    var authorizationRequested: Bool {
        UserDefaults.standard.bool(forKey: Self.authRequestedKey)
    }

    /// Name of the Apple Watch writing heart rate into HealthKit (e.g.
    /// "Rishi's Apple Watch"), or nil if no watch has contributed samples yet.
    /// Watch/Health-originated sources carry a "com.apple.health" bundle prefix.
    func fetchWatchSourceName() async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKSourceQuery(sampleType: HKQuantityType(.heartRate),
                                      samplePredicate: nil) { _, sources, _ in
                let watch = sources?.first {
                    $0.bundleIdentifier.hasPrefix("com.apple.health")
                    || $0.name.localizedCaseInsensitiveContains("watch")
                }
                continuation.resume(returning: watch?.name)
            }
            store.execute(query)
        }
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

    // MARK: - Latest aux vitals (SpO2 / blood pressure)

    /// Most recent blood-oxygen reading as a percentage (0–100), or nil if the
    /// user's devices haven't recorded one. HealthKit stores it as a 0–1
    /// fraction, converted here.
    func fetchLatestSpO2() async -> Double? {
        guard let fraction = await fetchLatest(quantityType: .oxygenSaturation, unit: .percent()) else { return nil }
        return fraction * 100
    }

    /// Most recent systolic/diastolic pair (mmHg), or nil if unavailable.
    func fetchLatestBloodPressure() async -> (systolic: Double, diastolic: Double)? {
        async let sys = fetchLatest(quantityType: .bloodPressureSystolic,  unit: .millimeterOfMercury())
        async let dia = fetchLatest(quantityType: .bloodPressureDiastolic, unit: .millimeterOfMercury())
        guard let s = await sys, let d = await dia else { return nil }
        return (s, d)
    }

    /// Value of the single most recent sample of `identifier`, or nil if none.
    private func fetchLatest(quantityType identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let type = HKQuantityType(identifier)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                guard let sample = (samples as? [HKQuantitySample])?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: sample.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    // MARK: - Fitness data (read-only, informational — Activity section)

    /// Today's step count, summed from midnight to now.
    func fetchTodaySteps() async -> Double {
        await fetchSum(quantityType: .stepCount, unit: .count(), from: Calendar.current.startOfDay(for: Date()), to: Date())
    }

    /// Today's active energy burned, in kilocalories.
    func fetchTodayActiveEnergy() async -> Double {
        await fetchSum(quantityType: .activeEnergyBurned, unit: .kilocalorie(), from: Calendar.current.startOfDay(for: Date()), to: Date())
    }

    /// Daily step totals for the last `days` days (including today), oldest
    /// first — used for the Fitness view's weekly trend chart.
    func fetchStepsTrend(days: Int = 7) async -> [(date: Date, steps: Double)] {
        var results: [(Date, Double)] = []
        let calendar = Calendar.current
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date())),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let total = await fetchSum(quantityType: .stepCount, unit: .count(), from: dayStart, to: dayEnd)
            results.append((dayStart, total))
        }
        return results
    }

    private func fetchSum(quantityType identifier: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async -> Double {
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                guard error == nil, let sum = statistics?.sumQuantity() else {
                    continuation.resume(returning: 0)
                    return
                }
                continuation.resume(returning: sum.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Recent workouts (any type — running, cycling, strength, etc.),
    /// most recent first.
    func fetchRecentWorkouts(limit: Int = 10) async -> [WorkoutSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: limit, sortDescriptors: [sortDescriptor]) { _, samples, error in
                guard error == nil, let workouts = samples as? [HKWorkout] else {
                    continuation.resume(returning: [])
                    return
                }
                let summaries = workouts.map { workout in
                    WorkoutSummary(
                        activityType: workout.workoutActivityType.displayName,
                        startDate: workout.startDate,
                        durationSeconds: workout.duration,
                        activeEnergyKcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                            .sumQuantity()?.doubleValue(for: .kilocalorie())
                    )
                }
                continuation.resume(returning: summaries)
            }
            store.execute(query)
        }
    }
}

struct WorkoutSummary: Identifiable {
    let id = UUID()
    let activityType: String
    let startDate: Date
    let durationSeconds: TimeInterval
    let activeEnergyKcal: Double?
}

private extension HKWorkoutActivityType {
    /// Human-readable label — HealthKit only gives you the raw enum.
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength Training"
        case .yoga: return "Yoga"
        case .hiking: return "Hiking"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .highIntensityIntervalTraining: return "HIIT"
        default: return "Workout"
        }
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
