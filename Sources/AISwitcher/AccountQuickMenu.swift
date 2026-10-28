import AppKit
import AISwitcherCore

/// Native menu actions carry only the profile ID; AppModel enforces lifecycle guards.
@MainActor
enum AccountQuickMenu {
    static func make(account: Account, model: AppModel, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func info(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = target
            item.representedObject = account.id
            item.isEnabled = enabled
            menu.addItem(item)
        }
        info(model.sessionStatus(for: account).title)
        if let quota = account.displayedCodexConnection?.quota {
            let stale = quota.isStale(at: Date()) || model.quotaErrors[account.id] != nil
            if stale { info(L10n.text("Stale data · refresh needed")) }
            for bucket in quota.limits.buckets {
                info(bucket.value.limitName ?? bucket.id)
                for window in [bucket.value.primary, bucket.value.secondary].compactMap({ $0 }) {
                    let percent = !window.resetHasPassed(at: Date()) ? window.remainingPercent : nil
                    let value = percent.map { L10n.format("%@%% remaining", $0.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))) } ?? (!window.resetHasPassed(at: Date()) ? window.remainingAmount.map { L10n.format("%@ remaining", $0.formatted()) } : nil) ?? L10n.text("No data yet")
                    info(window.durationLabel + " · " + value)
                    if let reset = window.resetDate { info(L10n.format("Reset: %@", L10n.dateTime(reset))) }
                }
            }
            info(L10n.format("Last read: %@", L10n.dateTime(quota.fetchedAt)))
        } else { info(account.effectiveAgent.supportsQuota ? L10n.text("No data yet") : L10n.text("Quota is not available for this agent.")) }
        if !account.effectiveAgent.supportsQuota {
            info(account.effectiveAgent.isSharedApplication ? L10n.text("Shared application sign-in") : account.usesClaudeDesktop ? L10n.text("Separate Desktop profile") : L10n.text("Separate browser profile"))
        }
        menu.addItem(.separator())
        let busy = model.launchingIDs.contains(account.id)
        let quotaBusy = model.quotaBusyIDs.contains(account.id)
        action(L10n.format("Default: %@", model.defaultActionTitle(for: account)), #selector(AppDelegate.openAccount(_:)), enabled: !busy && !quotaBusy)
        if account.effectiveAgent.usesProviderQuota {
            action(L10n.text("Connect account session"), #selector(AppDelegate.connectAccount(_:)), enabled: model.canConnectSession(account))
            action(L10n.text("Refresh quota"), #selector(AppDelegate.refreshAccountQuota(_:)), enabled: !busy && !quotaBusy)
        } else if account.usesCodexDesktop {
            action(L10n.text("Open ChatGPT Desktop"), #selector(AppDelegate.openDesktopAccount(_:)), enabled: !busy)
            action(L10n.text("Connect account session"), #selector(AppDelegate.connectAccount(_:)), enabled: model.canConnectSession(account))
            if model.hasRunningSession(account) {
                action(L10n.text("Refresh quota"), #selector(AppDelegate.refreshAccountQuota(_:)), enabled: !busy && !quotaBusy)
            }
        } else if account.effectiveAgent.supportsQuota {
            action(L10n.text("Refresh quota"), #selector(AppDelegate.refreshAccountQuota(_:)), enabled: !busy && !quotaBusy && account.codexConnection != nil)
        }
        if account.effectiveAgent.supportsQuota { action(L10n.text("Details"), #selector(AppDelegate.showAccountQuota(_:))) }
        action(L10n.text("Close account session…"), #selector(AppDelegate.closeAccount(_:)), enabled: (!account.effectiveAgent.isSharedApplication || model.providerSessionIDs.contains(account.id)) && !busy && !quotaBusy && model.runningIDs.contains(account.id))
        action(L10n.text("Session diagnostics"), #selector(AppDelegate.showSessionDiagnostics(_:)))
        return menu
    }
}
