import SwiftUI
import AISwitcherCore

struct QuotaNotificationSettingsView: View {
    @ObservedObject var model: AppModel
    private var appearanceTheme: AppTheme { model.preferences.theme }
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Quota alerts currently apply to ChatGPT/Codex accounts only."))
                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
            Toggle(L10n.text("Quota notifications"), isOn: Binding(get: { model.preferences.quotaAlerts.enabled }, set: { enabled in
                Task { await model.setQuotaNotifications(enabled) }
            })).toggleStyle(.switch).font(appearanceTheme.font(size: 13, weight: .semibold))
                .disabled(model.notificationSettingsBusy).accessibilityIdentifier("quotaNotifications")
            if model.notificationSettingsBusy { ProgressView().controlSize(.small) }
            Stepper(value: Binding(get: { model.preferences.quotaAlerts.threshold }, set: { model.setQuotaAlertThreshold($0) }), in: 1...95) {
                Text(L10n.format("Notify at or below %@%% remaining", String(model.preferences.quotaAlerts.threshold)))
                    .font(appearanceTheme.font(size: 11))
            }.accessibilityIdentifier("quotaThreshold")
            Toggle(L10n.text("Notify when quota recovers above the threshold"), isOn: Binding(
                get: { model.preferences.quotaAlerts.notifyRecovery }, set: { model.setQuotaRecoveryAlerts($0) }))
                .toggleStyle(.checkbox).font(appearanceTheme.font(size: 11))
            Text(L10n.text("Only fresh quota reads trigger alerts. Reset times alone never trigger recovery notifications. AI Switcher must be running."))
                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
            Text(model.notificationPermission.title).font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
            if let error = model.notificationError { Text(error).font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary) }
            Button(L10n.text("Check notification permission")) { Task { await model.refreshNotificationPermission() } }
                .font(appearanceTheme.font(size: 10))
        }.padding(14).background(palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)))
            .retroOutline(radius: appearanceTheme.radius(10), shadow: false)
            .task { await model.refreshNotificationPermission() }
    }

}
