// CardioAIApp.swift
// Entry point. Updated: checks Apple credential state on cold launch.

import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct CardioAIApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let container: DependencyContainer = .shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container.authService)
                .environmentObject(container.sessionManager)
                .environmentObject(container.alertStore)
                .environmentObject(container.deviceStore)
                .environmentObject(container.bridgeClient)
                .environmentObject(container.devicePairingService)
                .preferredColorScheme(.dark)
                .task {
                    // Restore session on cold launch
                    await container.authService.restoreSession()
                }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationService.shared.requestAuthorization()
        BackgroundTaskScheduler.shared.registerTasks()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundTaskScheduler.shared.scheduleHeartbeatTask()
    }
}
