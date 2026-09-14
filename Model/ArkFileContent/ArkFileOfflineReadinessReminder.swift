// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import Combine
import Foundation
import UserNotifications

enum ArkFileReminderAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

struct ArkFileReminderSystemSettings: Equatable {
    let authorization: ArkFileReminderAuthorization
    let alertsEnabled: Bool
    let scheduledDeliveryEnabled: Bool

    var deliveryIsLimited: Bool {
        authorization == .provisional
            || authorization == .ephemeral
            || !alertsEnabled
            || scheduledDeliveryEnabled
    }
}

struct ArkFileReminderPendingRequest: Equatable {
    let identifier: String
    let nextTriggerDate: Date?
}

protocol ArkFileReminderNotificationScheduling: AnyObject, Sendable {
    func settings() async -> ArkFileReminderSystemSettings
    func requestAuthorization() async throws -> Bool
    func addReminder(
        identifier: String,
        title: String,
        body: String,
        interval: TimeInterval,
        repeats: Bool
    ) async throws
    func pendingRequests() async -> [ArkFileReminderPendingRequest]
    func removePendingRequest(identifier: String)
    func removeDeliveredRequest(identifier: String)
}

final class ArkFileReminderNotificationCenterAdapter: ArkFileReminderNotificationScheduling, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func settings() async -> ArkFileReminderSystemSettings {
        let settings = await center.notificationSettings()
        let authorization: ArkFileReminderAuthorization = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .denied
        }
        return ArkFileReminderSystemSettings(
            authorization: authorization,
            alertsEnabled: settings.alertSetting == .enabled,
            scheduledDeliveryEnabled: settings.scheduledDeliverySetting == .enabled
        )
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func addReminder(
        identifier: String,
        title: String,
        body: String,
        interval: TimeInterval,
        repeats: Bool
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: repeats)
        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        ))
    }

    func pendingRequests() async -> [ArkFileReminderPendingRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map {
                    ArkFileReminderPendingRequest(
                        identifier: $0.identifier,
                        nextTriggerDate: ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                    )
                })
            }
        }
    }

    func removePendingRequest(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func removeDeliveredRequest(identifier: String) {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

enum ArkFileOfflineReadinessReminderDeliveryState: Equatable {
    case off
    case active
    case limited
    case denied
    case schedulingFailed
}

@MainActor
final class ArkFileOfflineReadinessReminder: ObservableObject {
    static let shared = ArkFileOfflineReadinessReminder()

    nonisolated static let notificationIdentifier = "app.arkfile.offline-readiness.reminder"
    nonisolated static let reminderIntervalDays = 21
    nonisolated static let reminderInterval: TimeInterval = TimeInterval(reminderIntervalDays * 24 * 60 * 60)
    nonisolated static let notificationTitle = "Check ArkFile offline"
    nonisolated static let notificationBody = "Open ArkFile and make sure your saved content opens offline before you need it."

    @Published private(set) var intentEnabled: Bool
    @Published private(set) var deliveryState: ArkFileOfflineReadinessReminderDeliveryState = .off
    @Published private(set) var lastOpenedAt: Date?
    @Published private(set) var nextReminderAt: Date?
    @Published private(set) var statusMessage: String?

    private let userDefaults: UserDefaults
    private let scheduler: ArkFileReminderNotificationScheduling
    private let now: () -> Date

    private enum DefaultsKey {
        static let intentEnabled = "arkfile.offlineReadiness.reminderIntentEnabled.v2"
        static let legacyPreference = "arkfile.offlineReadiness.preference"
        static let lastOpenedAt = "arkfile.offlineReadiness.lastOpenedAt"
        static let nextReminderAt = "arkfile.offlineReadiness.nextReminderAt"
    }

    init(
        userDefaults: UserDefaults = .standard,
        scheduler: ArkFileReminderNotificationScheduling = ArkFileReminderNotificationCenterAdapter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.scheduler = scheduler
        self.now = now
        self.intentEnabled = Self.migratedReminderIntent(in: userDefaults)
        self.lastOpenedAt = Self.date(for: DefaultsKey.lastOpenedAt, in: userDefaults)
        self.nextReminderAt = Self.date(for: DefaultsKey.nextReminderAt, in: userDefaults)
        self.deliveryState = intentEnabled ? .schedulingFailed : .off
    }

    var isConfigured: Bool {
        intentEnabled
    }

    func appDidBecomeActive() async {
        lastOpenedAt = now()
        persistDates()
        scheduler.removeDeliveredRequest(identifier: Self.notificationIdentifier)

        guard intentEnabled else {
            deliveryState = .off
            statusMessage = nil
            return
        }
        await reconcileAndSchedule(requestPermissionIfNeeded: false)
    }

    func refreshStatus() async {
        guard intentEnabled else {
            deliveryState = .off
            statusMessage = nil
            nextReminderAt = nil
            persistDates()
            return
        }
        await reconcileAndSchedule(requestPermissionIfNeeded: false)
    }

    func enableReminder() async {
        intentEnabled = true
        persistIntent()
        await reconcileAndSchedule(requestPermissionIfNeeded: true)
    }

    func turnOffReminder() {
        intentEnabled = false
        deliveryState = .off
        statusMessage = nil
        nextReminderAt = nil
        persistIntent()
        persistDates()
        scheduler.removePendingRequest(identifier: Self.notificationIdentifier)
        scheduler.removeDeliveredRequest(identifier: Self.notificationIdentifier)
    }

    func clearPreference() {
        turnOffReminder()
    }

    func recordReminderNotificationOpened() {
        lastOpenedAt = now()
        persistDates()
        scheduler.removeDeliveredRequest(identifier: Self.notificationIdentifier)
    }

    private func reconcileAndSchedule(requestPermissionIfNeeded: Bool) async {
        var settings = await scheduler.settings()

        if settings.authorization == .notDetermined, requestPermissionIfNeeded {
            do {
                _ = try await scheduler.requestAuthorization()
                settings = await scheduler.settings()
            } catch {
                await markSchedulingFailed("ArkFile could not request notification permission. Open Settings and allow notifications for ArkFile.")
                return
            }
        }

        switch settings.authorization {
        case .denied:
            deliveryState = .denied
            nextReminderAt = nil
            statusMessage = "Notifications are off for ArkFile. Allow notifications in Settings, then return here."
            persistDates()
        case .notDetermined:
            deliveryState = .schedulingFailed
            nextReminderAt = nil
            statusMessage = "Notification permission is needed before ArkFile can schedule readiness reminders."
            persistDates()
        case .authorized, .provisional, .ephemeral:
            await scheduleAndVerify(using: settings)
        }
    }

    private func scheduleAndVerify(using settings: ArkFileReminderSystemSettings) async {
        do {
            // Adding the same identifier replaces the pending request. Removing it
            // first is unnecessary and can race the asynchronous removal operation.
            try await scheduler.addReminder(
                identifier: Self.notificationIdentifier,
                title: Self.notificationTitle,
                body: Self.notificationBody,
                interval: Self.reminderInterval,
                repeats: true
            )
            await applyPendingState(settings: settings, replacementFailed: false)
        } catch {
            // Apple does not promise replacement atomicity on failure. Re-read
            // pending requests and preserve an existing valid reminder if present.
            await applyPendingState(settings: settings, replacementFailed: true)
        }
    }

    private func applyPendingState(
        settings: ArkFileReminderSystemSettings,
        replacementFailed: Bool
    ) async {
        let pending = await scheduler.pendingRequests().first {
            $0.identifier == Self.notificationIdentifier
        }
        guard let pending else {
            await markSchedulingFailed("ArkFile could not schedule the reminder. Check notification settings and try again.")
            return
        }

        deliveryState = settings.deliveryIsLimited ? .limited : .active
        nextReminderAt = pending.nextTriggerDate ?? now().addingTimeInterval(Self.reminderInterval)
        if replacementFailed {
            statusMessage = "The existing reminder is still scheduled, but ArkFile could not move its date."
        } else if settings.deliveryIsLimited {
            statusMessage = "Reminder scheduled. iOS or iPadOS may deliver it quietly or in Notification Summary."
        } else {
            statusMessage = "Offline readiness reminder scheduled."
        }
        persistDates()
    }

    private func markSchedulingFailed(_ message: String) async {
        deliveryState = .schedulingFailed
        nextReminderAt = nil
        statusMessage = message
        persistDates()
    }

    private func persistIntent() {
        userDefaults.set(intentEnabled, forKey: DefaultsKey.intentEnabled)
    }

    private func persistDates() {
        if let lastOpenedAt {
            userDefaults.set(lastOpenedAt.timeIntervalSince1970, forKey: DefaultsKey.lastOpenedAt)
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.lastOpenedAt)
        }
        if let nextReminderAt {
            userDefaults.set(nextReminderAt.timeIntervalSince1970, forKey: DefaultsKey.nextReminderAt)
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.nextReminderAt)
        }
    }

    private static func migratedReminderIntent(in userDefaults: UserDefaults) -> Bool {
        if userDefaults.object(forKey: DefaultsKey.intentEnabled) != nil {
            return userDefaults.bool(forKey: DefaultsKey.intentEnabled)
        }
        let legacy = userDefaults.string(forKey: DefaultsKey.legacyPreference)
        let enabled = legacy == "reminderEnabled" || legacy == "notificationsDenied"
        userDefaults.set(enabled, forKey: DefaultsKey.intentEnabled)
        return enabled
    }

    private static func date(for key: String, in userDefaults: UserDefaults) -> Date? {
        let timeInterval = userDefaults.double(forKey: key)
        guard timeInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: timeInterval)
    }
}
#endif
