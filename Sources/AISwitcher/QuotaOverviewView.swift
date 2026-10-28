import SwiftUI
import AISwitcherCore

struct SessionStatusBadge: View {
    @Environment(\.appTheme) private var theme
    let status: SessionStatus
    private var palette: ThemePalette { ThemePalette(theme: theme) }
    private var attention: Bool { status == .needsSignIn || status == .connectionFailed }
    private var symbol: String {
        switch status {
        case .background: return "network"
        case .desktopOpen: return "macwindow"
        case .browserOpen: return "globe"
        case .applicationRunning: return "app"
        case .needsSignIn: return "person.crop.circle.badge.exclamationmark"
        case .connectionFailed: return "exclamationmark.triangle"
        case .connecting, .opening, .closing: return "arrow.triangle.2.circlepath"
        case .disconnected: return "pause.circle"
        }
    }
    var body: some View {
        Label(status.title, systemImage: symbol)
            .font(theme.font(size: 10, weight: .medium))
            .foregroundColor(palette.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(attention ? AccountColor.gold.pale(for: theme) : palette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius(6)))
            .retroOutline(radius: theme.radius(6), shadow: false)
            .accessibilityElement(children: .combine)
    }
}

struct QuotaOverviewView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appTheme) private var theme
    private var palette: ThemePalette { ThemePalette(theme: theme) }
    private let widths: [CGFloat] = [166, 105, 105, 110, 110, 110]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let accounts = AccountQuotaOverview.sorted(model.visibleAccounts, key: model.preferences.quotaSortKey,
                ascending: model.preferences.quotaSortAscending, now: now, failedIDs: Set(model.quotaErrors.keys))
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("Select a column heading to sort. Missing or outdated values appear last."))
                    .font(theme.font(size: 11)).foregroundColor(palette.secondary)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        HStack(alignment: .center, spacing: 8) {
                            ForEach(Array(QuotaSortKey.allCases.enumerated()), id: \.element) { index, key in
                                sortHeading(key).frame(width: widths[index], alignment: .leading)
                            }
                            Text(L10n.text("Actions")).frame(width: widths[5], alignment: .leading)
                        }
                        .font(theme.font(size: 11, weight: .semibold))
                        .padding(12).background(theme.isPlayfulRetro ? palette.yellow : palette.canvas)
                        ForEach(accounts) { account in
                            Rectangle().fill(palette.line).frame(height: theme.isPlayfulRetro ? 2 : 1)
                            row(account, now: now)
                        }
                    }
                    .background(palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius(12)))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius(12)).stroke(palette.line))
                    .retroOutline(radius: theme.radius(12))
                    .padding(.trailing, theme.isPlayfulRetro ? 4 : 0).padding(.bottom, theme.isPlayfulRetro ? 4 : 0)
                }
                Text(L10n.text("Each row shows one limit group. Open Details to see every group and reset time."))
                    .font(theme.font(size: 10)).foregroundColor(palette.secondary)
            }
        }
        .accessibilityIdentifier("quotaOverview")
    }

    private func sortHeading(_ key: QuotaSortKey) -> some View {
        Button { model.setQuotaSort(key) } label: {
            HStack(spacing: 4) {
                Text(key.title)
                if model.preferences.quotaSortKey == key {
                    Image(systemName: model.preferences.quotaSortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(ThemedPlainButtonStyle())
        .accessibilityIdentifier("sort-\(key.rawValue)")
        .accessibilityValue(model.preferences.quotaSortKey == key ? (model.preferences.quotaSortAscending ? L10n.text("Ascending") : L10n.text("Descending")) : L10n.text("Not sorted"))
    }

    private func row(_ account: Account, now: Date) -> some View {
        let summary = AccountQuotaOverview(account: account, now: now, readFailed: model.quotaErrors[account.id] != nil)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    if account.effectiveAgent.supportsQuota { model.quotaAccountID = account.id }
                    else { model.open(account) }
                } label: {
                    HStack(spacing: 7) {
                        AccountAvatar(account: account, size: 25)
                        Text(account.name).font(theme.font(size: 12, weight: .semibold)).lineLimit(2)
                    }
                }.buttonStyle(ThemedPlainButtonStyle()).help(L10n.text("Details"))
                SessionStatusBadge(status: model.sessionStatus(for: account))
                Text(account.effectiveAgent.name).font(theme.font(size: 9)).foregroundColor(palette.secondary)
                if let name = summary.bucketName {
                    Text(name + (summary.bucketCount > 1 ? " +\(summary.bucketCount - 1)" : ""))
                        .font(theme.font(size: 9)).foregroundColor(palette.secondary).lineLimit(1)
                }
            }.frame(width: widths[0], alignment: .leading)
            quotaCell(account, window: summary.bucket?.primary, summary: summary).frame(width: widths[1], alignment: .leading)
            quotaCell(account, window: summary.bucket?.secondary, summary: summary).frame(width: widths[2], alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if let reset = summary.nextReset {
                    Text(reset, format: .dateTime.day().month().hour().minute())
                } else { Text(account.effectiveAgent.supportsQuota ? L10n.text("No data yet") : L10n.text("Not available")) }
            }.font(theme.font(size: 10)).foregroundColor(palette.secondary).frame(width: widths[3], alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if let read = summary.snapshot?.fetchedAt {
                    Text(read, format: .dateTime.day().month().hour().minute())
                    if summary.stale { Text(L10n.text("Stale data · refresh needed")).font(theme.font(size: 9, weight: .medium)) }
                } else { Text(account.effectiveAgent.supportsQuota ? L10n.text("No data yet") : L10n.text("Not available")) }
            }.font(theme.font(size: 10)).foregroundColor(palette.secondary).frame(width: widths[4], alignment: .leading)
            actions(account).frame(width: widths[5], alignment: .leading)
        }
        .padding(12).foregroundColor(palette.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quota-row-\(account.id)")
    }

    @ViewBuilder private func quotaCell(_ account: Account, window: CodexQuotaWindow?, summary: AccountQuotaOverview) -> some View {
        if account.effectiveAgent.supportsQuota { windowCell(window, summary: summary) }
        else { Text(L10n.text("Not available")).font(theme.font(size: 10)).foregroundColor(palette.secondary) }
    }

    private func windowCell(_ window: CodexQuotaWindow?, summary: AccountQuotaOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let percent = summary.remaining(window) {
                Text(L10n.format("%@%% remaining", percent.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))))
                    .font(theme.font(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundColor(summary.stale ? palette.secondary : palette.accent)
            } else if let window, !window.resetHasPassed(at: summary.now), let amount = window.remainingAmount {
                Text(L10n.format("%@ remaining", amount.formatted())).font(theme.font(size: 11, weight: .semibold))
            } else { Text(L10n.text("No data yet")).font(theme.font(size: 10)).foregroundColor(palette.secondary) }
            if let window {
                Text(window.durationLabel).font(theme.font(size: 9)).foregroundColor(palette.secondary)
                if window.resetHasPassed(at: summary.now) {
                    Text(L10n.text("Reset time reached · refresh needed")).font(theme.font(size: 9)).foregroundColor(palette.secondary)
                }
            }
        }
    }

    private func actions(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Button(!account.effectiveAgent.supportsQuota ? L10n.text("Open agent") : (account.usesCodexDesktop || account.effectiveAgent.usesProviderQuota) ? ((model.backendIDs.contains(account.id) || model.providerSessionIDs.contains(account.id)) ? L10n.text("Refresh") : L10n.text("Connect")) : L10n.text("Details")) {
                if !account.effectiveAgent.supportsQuota { model.open(account) }
                else if account.effectiveAgent.usesProviderQuota { model.providerSessionIDs.contains(account.id) ? model.refreshQuota(account) : model.connectSession(account) }
                else if account.usesCodexDesktop { model.refreshQuota(account) }
                else { model.quotaAccountID = account.id }
            }
            .font(theme.font(size: 10, weight: .semibold)).buttonStyle(ThemedPlainButtonStyle())
            .foregroundColor(palette.accent)
            .disabled(model.launchingIDs.contains(account.id) || model.quotaBusyIDs.contains(account.id))
            Menu {
                if account.effectiveAgent.supportsQuota { Button(L10n.text("Details")) { model.quotaAccountID = account.id } }
                Button(account.effectiveAgent.openTitle) { model.open(account) }
                Button(L10n.text("Edit profile…")) { model.editor = AccountEditor(account: account) }
                Button(L10n.text("Close account session…")) { model.accountToClose = account }
                    .disabled((account.effectiveAgent.isSharedApplication && !model.providerSessionIDs.contains(account.id)) || !model.runningIDs.contains(account.id) || model.quotaBusyIDs.contains(account.id))
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 20) }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.text("Profile options"))
                .disabled(model.launchingIDs.contains(account.id))
        }
    }
}
