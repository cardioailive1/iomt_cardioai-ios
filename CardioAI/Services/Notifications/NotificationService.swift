// NotificationService.swift
// Push notifications for critical cardiac alerts.

import Foundation
import UserNotifications

final class NotificationService: NSObject {

    static let shared = NotificationService()
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge, .criticalAlert]
        ) { granted, error in
            if let error { print("[Notifications] Auth error: \(error)") }
        }
    }

    func postCriticalAlert(_ alert: RPMAlert) {
        let content           = UNMutableNotificationContent()
        content.title         = "⚠️ CRITICAL — \(alert.alertLevel.displayName)"
        content.body          = alert.description
        content.sound         = .defaultCritical
        content.badge         = 1
        content.categoryIdentifier = "CRITICAL_ALERT"
        content.userInfo      = ["alert_id": alert.id, "patient_id": alert.patientID]

        let request = UNNotificationRequest(
            identifier: alert.id,
            content:    content,
            trigger:    nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
