import Foundation
import UserNotifications

/// Turns state transitions into notifications. Sub-threshold blips stay silent:
/// Starlink drops for a second or two many times an hour and nobody wants a banner for each.
@MainActor
final class Notifier {
    private var downSince: Date?
    private var announcedDown = false
    private var knownAlerts: Set<String> = []
    private var primed = false
    private var announcedReboot = false

    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func observe(state: LinkState, dish: DishStatus?, settings: Settings) {
        let now = Date()

        if state.isUp {
            if let since = downSince, announcedDown, settings.notifyOutages {
                post("Starlink is back online", "Down for \(Fmt.duration(now.timeIntervalSince(since))).")
            }
            downSince = nil
            announcedDown = false
        } else if primed {
            if downSince == nil { downSince = now }
            if let since = downSince, !announcedDown, now.timeIntervalSince(since) >= settings.outageThreshold {
                announcedDown = true
                if settings.notifyOutages { post("Starlink is offline", state.title) }
            }
        }

        if let dish {
            let serious = Set(dish.alerts).subtracting(DishStatus.benignAlerts)
            if primed, settings.notifyAlerts {
                for alert in serious.subtracting(knownAlerts) { post("Starlink alert", alert) }
                if dish.softwareUpdateState == 6, !announcedReboot {
                    announcedReboot = true
                    post("Starlink update ready", "The dish will reboot to finish installing new firmware.")
                }
            }
            if dish.softwareUpdateState != 6 { announcedReboot = false }
            knownAlerts = serious
            primed = true
        }
    }

    private func post(_ title: String, _ body: String) {
        guard available, !Settings.shared.alertsPaused else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
