import SwiftUI
import AISwitcherCore

enum DesktopCompatibility: Equatable {
    case available(String), unavailable(String)
}

struct SessionDiagnosticsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var detailAccount: Account?
    private var palette: ThemePalette { ThemePalette(theme: theme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("Session diagnostics")).font(theme.font(size: 23, weight: .semibold))
                Spacer()
                Button { model.refreshDiagnostics() } label: { Label(L10n.text("Check again"), systemImage: "arrow.clockwise") }
                    .buttonStyle(ThemedPlainButtonStyle()).font(theme.font(size: 11))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    compatibility
                    if model.loadFailed {
                        Text(L10n.text("Could not read data. The existing file has been preserved."))
                            .font(theme.font(size: 12)).foregroundColor(palette.secondary)
                        Button(L10n.text("Try again")) { model.reload(); model.refreshDiagnostics() }
                    }
                    if model.accounts.isEmpty { Text(L10n.text("Add an account to get started")).font(theme.font(size: 12)) }
                    ForEach(model.accounts) { account in diagnostic(account) }
                    Text(L10n.text("Checks use session status, app compatibility, and the last quota result. Passwords, tokens, and conversation contents are not inspected."))
                        .font(theme.font(size: 10)).foregroundColor(palette.secondary)
                }.padding(.trailing, 5).padding(.bottom, 5)
            }
            HStack {
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(26).frame(width: 680, height: 660).background(palette.canvas).foregroundColor(palette.ink)
        .onAppear { model.refreshDiagnostics() }
        .sessionRestartConfirmation(model: model)
        .sheet(item: $detailAccount) { account in
            QuotaDetailView(model: model, accountID: account.id).appAppearance(model.preferences)
        }
        .accessibilityIdentifier("sessionDiagnostics")
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("ChatGPT Desktop compatibility"), systemImage: "checkmark.shield")
                .font(theme.font(size: 13, weight: .semibold))
            switch model.desktopCompatibility {
            case .available(let version):
                Text(L10n.format("Desktop %@ · required session features found", version))
                    .font(theme.font(size: 11)).foregroundColor(palette.secondary)
            case .unavailable(let message):
                Text(message).font(theme.font(size: 11)).foregroundColor(palette.secondary)
                Text(L10n.text("Install or update the compatible ChatGPT Desktop app, then choose Check again. Browser profiles remain available."))
                    .font(theme.font(size: 11)).foregroundColor(palette.secondary)
            case nil: Text(L10n.text("Checking…")).font(theme.font(size: 11))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(theme.isPlayfulRetro ? palette.blue : palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius(12))).retroOutline(radius: theme.radius(12))
    }

    private func diagnostic(_ account: Account) -> some View {
        let busy = model.launchingIDs.contains(account.id) || model.quotaBusyIDs.contains(account.id)
        let storageError = model.diagnosticStorageErrors[account.id]
        let quota = account.displayedCodexConnection?.quota
        let missingBrowser = account.effectiveLaunchMode == .browser && model.browserService.applicationURL(for: account.browser) == nil
        let missingApplication = (account.effectiveAgent.isSharedApplication && model.agentApplications.applicationURL(for: account.effectiveAgent) == nil)
            || (account.usesClaudeDesktop && model.claudeDesktopService.applicationURL() == nil)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AccountAvatar(account: account, size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.name).font(theme.font(size: 14, weight: .semibold))
                    Text(account.effectiveAgent.name).font(theme.font(size: 10)).foregroundColor(palette.secondary)
                    SessionStatusBadge(status: model.sessionStatus(for: account))
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if let error = storageError, !account.effectiveAgent.supportsCodexQuota {
                Text(error).font(theme.font(size: 11)).foregroundColor(palette.secondary)
            }
            if account.effectiveAgent.usesProviderQuota, let error = model.quotaErrors[account.id] {
                Text(error.localizedDescription).font(theme.font(size: 11)).foregroundColor(palette.secondary)
            }
            if !account.effectiveAgent.supportsCodexQuota {
                Text(account.effectiveAgent.supportDetail).font(theme.font(size: 11)).foregroundColor(palette.secondary)
                if missingApplication {
                    Text(L10n.format("%@ is not installed. Install the app, then try again.", account.effectiveAgent.name))
                        .font(theme.font(size: 11)).foregroundColor(palette.secondary)
                }
                if missingBrowser {
                    Text(L10n.format("Install %@ to use this browser profile.", account.browser.name))
                        .font(theme.font(size: 11)).foregroundColor(palette.secondary)
                }
            } else if let error = storageError {
                Text(error).font(theme.font(size: 11)).foregroundColor(palette.secondary)
                Text(L10n.text("Profile storage could not be verified. Reconnect and restart are disabled to preserve its data."))
                    .font(theme.font(size: 11)).foregroundColor(palette.secondary)
            } else if missingBrowser {
                Text(L10n.format("Install %@ to use this browser profile.", account.browser.name))
                    .font(theme.font(size: 11)).foregroundColor(palette.secondary)
            } else if let error = model.quotaErrorDescription(for: account) {
                Text(error).font(theme.font(size: 11)).foregroundColor(palette.secondary)
            } else if model.sessionStatus(for: account) == .disconnected {
                Text(L10n.text("The session is stopped. Retry connects in the background using the saved sign-in."))
                    .font(theme.font(size: 11)).foregroundColor(palette.secondary)
            } else {
                Text(L10n.text("No session error reported. Use Retry to read current quota."))
                    .font(theme.font(size: 11)).foregroundColor(palette.secondary)
            }
            if let date = model.lastQuotaChecks[account.id] {
                Text(L10n.format("Last check: %@", L10n.dateTime(date))).font(theme.font(size: 10)).foregroundColor(palette.secondary)
            }
            if let quota {
                Text(L10n.format("Last read: %@", L10n.dateTime(quota.fetchedAt))).font(theme.font(size: 10)).foregroundColor(palette.secondary)
                if quota.isStale(at: Date()) || model.quotaErrors[account.id] != nil {
                    Text(L10n.text("Previously read data; refresh to see current quota.")).font(theme.font(size: 10)).foregroundColor(palette.secondary)
                }
            }
            HStack(spacing: 12) {
                if account.effectiveAgent.supportsCodexQuota {
                Button(L10n.text("Try again")) {
                    if account.effectiveLaunchMode == .browser && account.codexConnection == nil { detailAccount = account }
                    else { model.refreshQuota(account) }
                }.buttonStyle(PrimaryButtonStyle(compact: true)).disabled(busy || storageError != nil || missingBrowser)
                if account.usesCodexDesktop {
                    Button(L10n.text("Restart session…")) { model.accountToRestart = account }
                        .disabled(busy || storageError != nil)
                }
                }
                Button(account.effectiveAgent.openTitle) { model.open(account) }.disabled(busy || storageError != nil || missingBrowser || missingApplication)
                Spacer(minLength: 0)
            }.font(theme.font(size: 11))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius(12))).retroOutline(radius: theme.radius(12))
    }
}

extension View {
    func sessionRestartConfirmation(model: AppModel, enabled: Bool = true) -> some View {
        alert(L10n.text("Restart this account session?"), isPresented: Binding(
            get: { enabled && model.accountToRestart != nil },
            set: { if !$0 { model.accountToRestart = nil } }
        ), presenting: model.accountToRestart) { account in
            Button(L10n.text("Cancel"), role: .cancel) { model.accountToRestart = nil }
            Button(L10n.text("Restart in background")) { model.restartSession(account); model.accountToRestart = nil }
        } message: { account in
            Text(L10n.format("Windows for “%@” will close. Send or copy drafts first. Only this profile restarts in the background; your saved sign-in is kept.", account.name))
        }
    }
}
