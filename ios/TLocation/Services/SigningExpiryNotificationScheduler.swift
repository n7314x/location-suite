import Foundation
import UserNotifications

final class SigningExpiryNotificationScheduler {
    static let shared = SigningExpiryNotificationScheduler()

    private let center: UNUserNotificationCenter
    private let identifiers = [
        "signing-expiry-72h",
        "signing-expiry-48h",
        "signing-expiry-24h",
    ]

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorizationAndSchedule(expirationDate: Date?) async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }
            await schedule(expirationDate: expirationDate)
        } catch {
            LogManager.shared.addWarningLog("Signing reminder permission was not granted.")
        }
    }

    func scheduleIfAuthorized(expirationDate: Date?) {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            Task { await self.schedule(expirationDate: expirationDate) }
        }
    }

    @MainActor
    private func content(hours: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Location Suite signing expires soon"
        content.body = "Open Location Suite to renew its provisioning profile. About \(hours) hours remain."
        content.sound = .default
        return content
    }

    private func schedule(expirationDate: Date?) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        guard let expirationDate else { return }
        let thresholds = [72, 48, 24]
        let dates = SigningReminderSchedule.dates(expirationDate: expirationDate)
        for (date, hours) in zip(dates, thresholds.suffix(dates.count)) {
            let content = await content(hours: hours)
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )
            let request = UNNotificationRequest(
                identifier: "signing-expiry-\(hours)h",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }
}
