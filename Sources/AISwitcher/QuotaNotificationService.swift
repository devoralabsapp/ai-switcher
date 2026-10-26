import AppKit
import UserNotifications
import AISwitcherCore

enum QuotaNotificationPermission: Equatable {
    case unavailable, notRequested, allowed, denied
    var title: String {
        switch self {
        case .unavailable: return L10n.text("Open the packaged AI Switcher app to use notifications.")
        case .notRequested: return L10n.text("Notification permission has not been requested.")
        case .allowed: return L10n.text("Notifications are allowed by macOS.")
        case .denied: return L10n.text("Notifications are blocked. Enable AI Switcher in macOS System Settings → Notifications.")
        }
    }
}

@MainActor
protocol QuotaNotificationSending {
    func permission() async -> QuotaNotificationPermission
    func requestPermission() async throws -> Bool
    func send(_ events: [QuotaAlertEvent], accountName: String, sound: Bool) async throws
    func clearPending()
}

@MainActor
final class QuotaNotificationService: NSObject, QuotaNotificationSending, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter requires a real app bundle, not swift test/CLI.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }
    var onSelectAccount: ((UUID) -> Void)?
    override init() {
        super.init()
        center?.delegate = self
    }
    func permission() async -> QuotaNotificationPermission {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .notRequested
        }
    }
    func requestPermission() async throws -> Bool {
        guard let center else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    func send(_ events: [QuotaAlertEvent], accountName: String, sound: Bool) async throws {
        guard let center, !events.isEmpty, await permission() == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.format("Quota update · %@", accountName)
        content.body = events.map { event in
            let percent = event.remaining.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))
            let text = event.kind == .low ? L10n.format("Low quota: %@%% remaining", percent) : L10n.format("Quota recovered: %@%% remaining", percent)
            return event.bucket + " · " + event.window.durationLabel + ": " + text
        }.joined(separator: "\n")
        content.userInfo = ["accountID": events[0].accountID.uuidString]
        if sound { content.sound = .default }
        try await center.add(UNNotificationRequest(identifier: "quota-" + events[0].accountID.uuidString, content: content, trigger: nil))
    }
    func clearPending() { center?.removeAllPendingNotificationRequests() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["accountID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let id { self.onSelectAccount?(id) }
            completionHandler()
        }
    }
}
