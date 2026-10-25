import SwiftUI
import AISwitcherCore

struct QuotaSummaryView: View {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    @ObservedObject var model: AppModel
    let account: Account

    private var emptyStatus: String {
        if account.effectiveLaunchMode == .browser {
            return model.connectingID == account.id ? L10n.text("Waiting for sign-in…") : L10n.text("Not connected")
        }
        if model.quotaBusyIDs.contains(account.id) { return L10n.text("Reading Desktop quota…") }
        if !model.runningIDs.contains(account.id) { return L10n.text("Open Desktop to read quota") }
        if let error = model.quotaErrors[account.id] {
            return (error as? CodexQuotaError) == .notSignedIn
                ? L10n.text("Waiting for Desktop sign-in…")
                : L10n.text("Could not read quota · view details")
        }
        return L10n.text("Detecting Desktop session…")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(L10n.text("Codex quota"), systemImage: "gauge").font(appearanceTheme.font(size: 11, weight: .semibold))
                    Spacer()
                    if model.quotaBusyIDs.contains(account.id) {
                        ProgressView().controlSize(.mini)
                    } else if account.displayedCodexConnection != nil || (account.effectiveLaunchMode == .desktop && model.runningIDs.contains(account.id)) {
                        Button { model.refreshQuota(account) } label: { Image(systemName: "arrow.clockwise").font(appearanceTheme.font(size: 11)) }
                            .buttonStyle(.plain).help(L10n.text("Refresh Codex quota"))
                    }
                }
                if let connection = account.displayedCodexConnection {
                    Button { model.quotaAccountID = account.id } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(connection.identity.email ?? L10n.text("Verified Codex identity"))
                                .font(appearanceTheme.font(size: 9)).lineLimit(1).foregroundColor(palette.secondary)
                            if let quota = connection.quota, let bucket = quota.limits.buckets.first {
                                if bucket.id != "codex" {
                                    Text(bucket.value.limitName ?? bucket.id).font(appearanceTheme.font(size: 9, weight: .medium)).foregroundColor(palette.secondary)
                                }
                                QuotaBucketView(bucket: bucket.value, now: timeline.date, compact: true,
                                                stale: quota.isStale(at: timeline.date) || model.quotaErrors[account.id] != nil)
                                Text(model.quotaErrors[account.id] != nil ? L10n.text("Refresh failed · previously read data") : quota.isStale(at: timeline.date) ? L10n.text("Stale data · refresh needed") : L10n.format("Read at %@ · Details ↗", String(describing: L10n.time(quota.fetchedAt))))
                                    .font(appearanceTheme.font(size: 9)).foregroundColor(model.quotaErrors[account.id] != nil ? .orange : palette.secondary)
                            } else {
                                Text(model.quotaErrors[account.id] == nil ? L10n.text("No limit data yet · view details") : L10n.text("Could not read quota · view details"))
                                    .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L10n.text("View quota, reset times, and the connected Codex account"))
                } else {
                    HStack {
                        Text(emptyStatus)
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        Spacer()
                        Button(account.effectiveLaunchMode == .desktop || model.connectingID == account.id ? L10n.text("Details") : L10n.text("Connect")) { model.quotaAccountID = account.id }
                            .buttonStyle(.plain).font(appearanceTheme.font(size: 10, weight: .semibold)).foregroundColor(palette.accent)
                    }
                }
            }
        }
        .padding(12).background(palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(9)))
    }
}

private struct QuotaBucketView: View {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    let bucket: CodexQuotaBucket
    let now: Date
    var compact = false
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 15) {
            if bucket.primary == nil && bucket.secondary == nil {
                Text(L10n.text("Codex has not returned a quota window.")).font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
            }
            if let window = bucket.primary { windowView(window) }
            if let window = bucket.secondary { windowView(window) }
            if bucket.rateLimitReachedType != nil {
                Text(L10n.text("Codex reports a quota or workspace limit has been reached."))
                    .font(appearanceTheme.font(size: 10)).foregroundColor(.orange)
            }
        }
    }

    private func windowView(_ window: CodexQuotaWindow) -> some View {
        let expired = window.resetHasPassed(at: now)
        let remaining = expired ? nil : window.remainingPercent
        let color: Color = stale || expired ? palette.secondary : (remaining ?? 100) <= 10 ? .red : (remaining ?? 100) <= 25 ? .orange : palette.accent
        return VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack {
                Text(window.durationLabel).foregroundColor(palette.secondary)
                Spacer()
                Text(remaining.map { L10n.format("%@%% remaining", String(describing: $0.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)))) } ?? L10n.text("No data yet"))
                    .fontWeight(.semibold).foregroundColor(color)
            }.font(appearanceTheme.font(size: compact ? 10 : 12))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.line)
                    Capsule().fill(color).frame(width: geometry.size.width * CGFloat((remaining ?? 0) / 100))
                }
            }.frame(height: compact ? 4 : 6).accessibilityHidden(true)
            if expired {
                Text(L10n.text("Reset time reached · refresh needed")).font(appearanceTheme.font(size: compact ? 9 : 11)).foregroundColor(.orange)
            } else if let date = window.resetDate {
                HStack(spacing: 3) {
                    Text("Reset")
                    Text(date, format: .dateTime.day().month().hour().minute())
                }.font(appearanceTheme.font(size: compact ? 9 : 11)).foregroundColor(palette.secondary)
            } else if !compact {
                Text(L10n.text("Codex has not provided a reset time.")).font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct QuotaDetailView: View {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    @ObservedObject var model: AppModel
    let accountID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    @State private var executableRevision = 0

    private var account: Account? { model.accounts.first { $0.id == accountID } }
    private var busy: Bool { model.quotaBusyIDs.contains(accountID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Codex quota")).font(appearanceTheme.font(size: 23, weight: .semibold))
                    Text(account?.name ?? L10n.text("Profile")).font(appearanceTheme.font(size: 12)).foregroundColor(palette.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.text("Close"))
            }.padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let pending = model.pendingConnections[accountID] {
                        confirmation(pending)
                    } else if let account, let connection = account.displayedCodexConnection {
                        connected(account, connection)
                    } else if let account {
                        onboarding(account)
                    }
                    if let account, let message = model.quotaErrorDescription(for: account) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(appearanceTheme.font(size: 11)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
            }
            HStack {
                if busy { ProgressView().controlSize(.small); Text(L10n.text("Working…")).font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary) }
                Spacer()
                Button(L10n.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.top, 20)
        }
        .padding(28).frame(width: 530, height: 600).background(palette.surface).foregroundColor(palette.ink)

        .onAppear {
            if let account, account.effectiveLaunchMode == .desktop, model.runningIDs.contains(accountID) {
                model.refreshQuota(account)
            }
        }
        .onDisappear { model.cancelQuotaConnection(accountID) }
        .alert(L10n.text("Disconnect Codex?"), isPresented: $confirmDisconnect) {
            Button(L10n.text("Cancel"), role: .cancel) { }
            Button(L10n.text("Disconnect"), role: .destructive) { model.disconnectQuota(accountID) }
        } message: {
            Text(L10n.text("This profile's separate local Codex session and cached quota will be deleted. Your ChatGPT windows and Codex accounts in other apps are kept."))
        }
    }

    @ViewBuilder
    private func onboarding(_ account: Account) -> some View {
        if account.effectiveLaunchMode == .desktop {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("Quota from this Desktop session")).font(appearanceTheme.font(size: 15, weight: .semibold))
                Text(L10n.text("Quota appears automatically after you sign in to this profile's ChatGPT Desktop window. No separate Codex sign-in is needed."))
                    .font(appearanceTheme.font(size: 12)).lineSpacing(4).foregroundColor(palette.secondary)
                Text(L10n.text("AI Switcher checks the Desktop session every few seconds until quota is available, then refreshes every 5 minutes. To change accounts, sign out inside that ChatGPT window."))
                    .font(appearanceTheme.font(size: 11)).lineSpacing(4).foregroundColor(palette.secondary)
                Button { model.open(account) } label: { Label(L10n.text("Open ChatGPT Desktop"), systemImage: "macwindow") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(model.launchingIDs.contains(accountID))
                Button(L10n.text("Refresh quota")) { model.refreshQuota(account) }.disabled(busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Connect this profile once")).font(appearanceTheme.font(size: 15, weight: .semibold))
            Text(L10n.text("Sign in to the intended Codex account in this profile's browser window. Then check its identity and confirm to attach quota to the card."))
                .font(appearanceTheme.font(size: 12)).lineSpacing(4).foregroundColor(palette.secondary)
            Text(L10n.text("Codex CLI stores OAuth in a separate local directory and refreshes quota every 5 minutes. This connection is separate from browser ChatGPT sign-in. AI Switcher does not read Chrome cookies or use your default Codex session."))
                .font(appearanceTheme.font(size: 11)).lineSpacing(4).foregroundColor(palette.secondary)
                .padding(13).background(palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(9)))
            if model.connectingID == accountID {
                Label(L10n.text("Finish signing in in the window that just opened."), systemImage: "arrow.up.right.square")
                    .font(appearanceTheme.font(size: 12)).foregroundColor(palette.accent)
                Button(L10n.text("Cancel sign-in")) { model.cancelQuotaConnection(accountID) }.disabled(!busy)
            } else {
                Button { model.connectQuota(account) } label: { Label(L10n.text("Sign in to Codex"), systemImage: "person.crop.circle.badge.checkmark") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(busy || model.connectingID != nil || model.quotaService.executableURL == nil)
                if model.connectingID != nil { Text(L10n.text("Finish connecting the other profile first.")).font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text(model.quotaService.executableURL == nil ? L10n.text("Install Codex CLI to read quota.") : L10n.text("Codex CLI found on this Mac."))
                    .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary).id(executableRevision)
                HStack {
                    Button(L10n.text("Choose Codex CLI…")) { model.quotaService.chooseExecutable(); executableRevision += 1 }.disabled(busy)
                    Link(L10n.text("Installation guide"), destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
                }.font(appearanceTheme.font(size: 11))
            }
        }
    }
    }

    private func confirmation(_ connection: CodexConnection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("Signed in successfully"), systemImage: "checkmark.circle.fill").foregroundColor(palette.accent)
            identity(connection.identity)
            Text(L10n.format("Check that this is the right account for “%@”. AI Switcher does not verify the account signed in to browser ChatGPT.", String(describing: account?.name ?? "")))
                .font(appearanceTheme.font(size: 12)).lineSpacing(4).foregroundColor(palette.secondary)
            Text(L10n.text("After confirmation, AI Switcher opens ChatGPT in this profile so you can check its account."))
                .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
            Button(L10n.text("Use this account")) { if model.confirmQuotaConnection(accountID) { dismiss() } }
                .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(busy)
            Button(L10n.text("Cancel and choose another account")) { model.cancelQuotaConnection(accountID) }.disabled(busy)
        }
    }

    private func connected(_ account: Account, _ connection: CodexConnection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            identity(connection.identity)
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                VStack(alignment: .leading, spacing: 20) {
                    if let quota = connection.quota {
                        ForEach(quota.limits.buckets, id: \.id) { bucket in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(bucket.value.limitName ?? (bucket.id == "codex" ? "Codex" : bucket.id))
                                    .font(appearanceTheme.font(size: 13, weight: .semibold))
                                QuotaBucketView(bucket: bucket.value, now: timeline.date,
                                                stale: quota.isStale(at: timeline.date) || model.quotaErrors[accountID] != nil)
                            }.padding(15).background(palette.canvas).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)))
                        }
                        if quota.limits.buckets.isEmpty { Text(L10n.text("Codex has not returned limits for this account.")).font(appearanceTheme.font(size: 12)) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.format("Last read: %@", String(describing: L10n.dateTime(quota.fetchedAt))))
                            if quota.isStale(at: timeline.date) || model.quotaErrors[accountID] != nil {
                                Text(L10n.text("Previously read data; refresh to see current quota.")).foregroundColor(.orange)
                            }
                        }.font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                    } else { Text(L10n.text("Could not read quota data. Choose Refresh to try again.")).font(appearanceTheme.font(size: 12)) }
                }
            }
            HStack {
                Button { model.refreshQuota(account) } label: { Label(L10n.text("Refresh"), systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(busy)
                Spacer()
                if account.effectiveLaunchMode == .browser {
                    Button(L10n.text("Disconnect…")) { confirmDisconnect = true }.disabled(busy)
                }
            }
            Text(L10n.text("Percentages show remaining quota returned by Codex. A missing window does not mean unlimited use. Reading quota does not run AI tasks."))
                .font(appearanceTheme.font(size: 10)).lineSpacing(4).foregroundColor(palette.secondary)
        }
    }

    private func identity(_ identity: CodexIdentity) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(identity.email ?? L10n.text("Verified Codex account")).font(appearanceTheme.font(size: 14, weight: .semibold)).textSelection(.enabled)
            Text(L10n.format("Plan: %@", String(describing: identity.planType ?? L10n.text("No data yet")))).font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
        }
    }
}
