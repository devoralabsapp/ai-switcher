import SwiftUI
import AISwitcherCore

struct Dashboard: View {
    private var appearanceTheme: AppTheme { model.preferences.theme }
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230).background(palette.sidebar)
            Rectangle().fill(palette.line).frame(width: appearanceTheme.dividerWidth)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(palette.line).frame(height: appearanceTheme.dividerWidth)
                ScrollView {
                    VStack(alignment: .leading, spacing: 27) {
                        hero
                        if model.loadFailed { recoveryBanner }
                        accountSection
                        if model.accounts.isEmpty { setupSteps }
                    }
                    .padding(32)
                }
                footer
            }
            .background(palette.canvas)
        }
        .foregroundColor(palette.ink)
        .background(palette.surface)
        .frame(minWidth: 900, minHeight: 640)
        .sheet(item: $model.editor) { editor in AccountEditorView(model: model, editor: editor) }
        .sheet(isPresented: $model.showPreferences) { PreferencesView(model: model) }
        .sheet(isPresented: $model.showGuide) { GuideView().appAppearance(model.preferences) }
        .sheet(isPresented: Binding(get: { model.quotaAccountID != nil }, set: { if !$0 { model.quotaAccountID = nil } })) {
            if let id = model.quotaAccountID { QuotaDetailView(model: model, accountID: id).appAppearance(model.preferences) }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text(L10n.text("Got it"))))
        }
        .alert(L10n.text("Delete this local profile?"), isPresented: Binding(
            get: { model.accountToDelete != nil },
            set: { if !$0 { model.accountToDelete = nil } }
        ), presenting: model.accountToDelete) { account in
            Button(L10n.text("Cancel"), role: .cancel) { model.accountToDelete = nil }
            Button(L10n.text("Delete profile"), role: .destructive) { model.delete(account); model.accountToDelete = nil }
        } message: { account in
            Text(L10n.format("The “%@” profile and its local Desktop, browser, and backend data will be deleted. Service accounts and conversation history are kept.", String(describing: account.name)))
        }
        .alert(L10n.text("Close this account session?"), isPresented: Binding(
            get: { model.accountToClose != nil },
            set: { if !$0 { model.accountToClose = nil } }
        ), presenting: model.accountToClose) { account in
            Button(L10n.text("Cancel"), role: .cancel) { model.accountToClose = nil }
            Button(L10n.text("Close session")) { model.closeSession(account); model.accountToClose = nil }
        } message: { account in
            Text(L10n.format("Windows for “%@” will close. Send or copy any drafts first. Your login is kept for next time.", String(describing: account.name)))
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAccountSearch)) { _ in searchFocused = true }
        .appAppearance(model.preferences)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.swap")
                    .font(appearanceTheme.font(size: 18, weight: .semibold))
                    .foregroundColor(palette.onAction)
                    .frame(width: 35, height: 35)
                    .background(palette.action)
                    .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(10)))
                    .retroOutline(radius: appearanceTheme.radius(10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Switcher").font(appearanceTheme.font(size: 16, weight: .bold))
                    Text(L10n.text("One click to your account")).font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 38)

            Text(L10n.text("YOUR WORKSPACE"))
                .font(appearanceTheme.font(size: 9, weight: .semibold)).tracking(1.4)
                .foregroundColor(palette.secondary).padding(.bottom, 12).padding(.leading, 10)
            ForEach(AccountFilter.allCases, id: \.self) { filter in
                Button {
                    model.filter = filter
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: filter.symbol).font(appearanceTheme.font(size: 14)).frame(width: 18)
                        Text(filter.title).font(appearanceTheme.font(size: 12, weight: model.filter == filter ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if filter == .all {
                            Text("\(model.accounts.count)").font(appearanceTheme.font(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(model.filter == filter ? palette.surface.opacity(0.85) : palette.canvas)
                                .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(5)))
                        }
                    }
                    .foregroundColor(appearanceTheme.isPlayfulRetro ? palette.ink : model.filter == filter ? palette.accent : palette.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 12)
                    .background(model.filter == filter ? (appearanceTheme.isPlayfulRetro ? palette.mint : palette.accent.opacity(0.08)) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(8)))
                    .retroOutline(radius: appearanceTheme.radius(8), shadow: model.filter == filter, enabled: model.filter == filter)
                }
                .buttonStyle(ThemedPlainButtonStyle())
                .padding(.bottom, 4)
            }

            if let account = model.lastOpened {
                VStack(alignment: .leading, spacing: 13) {
                    Text(L10n.text("OPEN AGAIN")).font(appearanceTheme.font(size: 9, weight: .semibold)).tracking(1.2)
                        .foregroundColor(palette.secondary)
                    Button { model.open(account) } label: {
                        HStack(spacing: 10) {
                            AccountAvatar(account: account, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.name).font(appearanceTheme.font(size: 12, weight: .medium)).lineLimit(1)
                                Text(L10n.text("Open ChatGPT ↗")).font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(ThemedPlainButtonStyle())
                }
                .padding(.horizontal, 10).padding(.top, 30)
            }

            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 20) {
                Button { model.showPreferences = true } label: {
                    Label(L10n.text("Appearance & Language"), systemImage: "paintpalette").font(appearanceTheme.font(size: 12))
                }.buttonStyle(ThemedPlainButtonStyle()).accessibilityIdentifier("openPreferences")
                Button { model.showGuide = true } label: {
                    Label(L10n.text("How it works"), systemImage: "questionmark.circle").font(appearanceTheme.font(size: 12))
                }.buttonStyle(ThemedPlainButtonStyle())
                Button { model.revealData() } label: {
                    Label(L10n.text("Local data"), systemImage: "externaldrive").font(appearanceTheme.font(size: 12))
                }.buttonStyle(ThemedPlainButtonStyle())
                Rectangle().fill(palette.line).frame(height: appearanceTheme.dividerWidth)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").font(appearanceTheme.font(size: 13)).foregroundColor(palette.accent)
                    Text(L10n.text("Each account has its own\nChatGPT Desktop session."))
                        .font(appearanceTheme.font(size: 10)).lineSpacing(4).foregroundColor(palette.secondary)
                }
            }
            .foregroundColor(palette.secondary)
            .padding(.horizontal, 10).padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                if appearanceTheme == .terminal {
                    Text("~/accounts $ ai-switcher").foregroundColor(palette.accent)
                } else if appearanceTheme == .code {
                    Label("accounts.workspace", systemImage: "chevron.left.forwardslash.chevron.right").foregroundColor(palette.secondary)
                } else { Text(L10n.text("Workspace")).foregroundColor(palette.secondary) }
                Image(systemName: "chevron.right").font(appearanceTheme.font(size: 8, weight: .semibold)).foregroundColor(palette.secondary.opacity(0.6))
                Text("ChatGPT").fontWeight(.medium)
            }.font(appearanceTheme.font(size: 11))
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(palette.secondary)
                TextField(L10n.text("Find accounts"), text: $model.search)
                    .textFieldStyle(.plain).focused($searchFocused).font(appearanceTheme.font(size: 11))
                    .accessibilityIdentifier("accountSearch")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(ThemedPlainButtonStyle()).foregroundColor(palette.secondary).help(L10n.text("Clear search"))
                } else { Text("⌘ K").font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary) }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(width: 212).background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(7)))
            .overlay(RoundedRectangle(cornerRadius: appearanceTheme.radius(7)).stroke(palette.line))
            .retroOutline(radius: appearanceTheme.radius(7), shadow: false)
        }
        .padding(.horizontal, 30).frame(height: 66)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(palette.accent).frame(width: 5, height: 5)
                    Text(L10n.text("FEWER CLICKS. KEEP YOUR FLOW."))
                        .font(appearanceTheme.font(size: 9, weight: .semibold)).tracking(1.2)
                }.foregroundColor(appearanceTheme.isPlayfulRetro ? palette.ink : palette.accent)
                Text(L10n.text("Multiple accounts.\nOne click."))
                    .font(appearanceTheme.font(size: 32, weight: .semibold)).tracking(-1.2).lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Sign in to each account once.\nSwitch freely, keep your conversations going."))
                    .font(appearanceTheme.font(size: 12)).lineSpacing(5).foregroundColor(palette.secondary)
            }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(palette.accent.opacity(0.08), lineWidth: 1).frame(width: 154, height: 154)
                Circle().stroke(palette.accent.opacity(0.05), lineWidth: 1).frame(width: 188, height: 188)
                RoundedRectangle(cornerRadius: appearanceTheme.radius(16)).fill(appearanceTheme.isPlayfulRetro ? palette.pink : palette.surface).frame(width: 63, height: 63)
                    .retroOutline(radius: appearanceTheme.radius(16))
                    .rotationEffect(.degrees(-13)).offset(x: -37, y: -26)
                    .shadow(color: palette.ink.opacity(0.04), radius: 10, y: 5)
                Image(systemName: "person.fill").font(appearanceTheme.font(size: 23)).foregroundColor(AccountColor.violet.tint(for: appearanceTheme))
                    .offset(x: -37, y: -26)
                RoundedRectangle(cornerRadius: appearanceTheme.radius(16)).fill(appearanceTheme.isPlayfulRetro ? palette.blue : palette.accent).frame(width: 63, height: 63)
                    .retroOutline(radius: appearanceTheme.radius(16))
                    .rotationEffect(.degrees(10)).offset(x: 30, y: 23)
                    .shadow(color: palette.accent.opacity(0.15), radius: 10, y: 5)
                Image(systemName: "person.fill").font(appearanceTheme.font(size: 23)).foregroundColor(appearanceTheme.isPlayfulRetro ? palette.ink : palette.onAccent).offset(x: 30, y: 23)
                Image(systemName: "arrow.triangle.swap").font(appearanceTheme.font(size: 18, weight: .semibold))
                    .foregroundColor(palette.accent).offset(x: 33, y: -38)
            }
            .frame(width: 190, height: 180).accessibilityHidden(true)
        }
        .retroPanel(fill: palette.yellow, radius: 18, padding: 22)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(model.filter.title).font(appearanceTheme.font(size: 17, weight: .semibold))
                        Text("\(model.visibleAccounts.count)")
                            .font(appearanceTheme.font(size: 10, weight: .semibold)).foregroundColor(palette.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(appearanceTheme.isPlayfulRetro ? palette.pink : palette.line.opacity(0.5))
                            .clipShape(Capsule()).retroOutline(radius: 100, shadow: false)
                    }
                    Text(L10n.text("A separate login session for each account."))
                        .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
                }
                Spacer()
                Button { model.addAccount() } label: { Label(L10n.text("Add account"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(model.loadFailed)
                    .accessibilityIdentifier("addAccount")
            }
            if model.visibleAccounts.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: appearanceTheme.isPlayfulRetro ? 20 : 16, alignment: .top)], spacing: appearanceTheme.isPlayfulRetro ? 20 : 16) {
                    ForEach(model.visibleAccounts) { account in AccountCard(model: model, account: account) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: model.accounts.isEmpty ? "person.badge.plus" : "magnifyingglass")
                .font(appearanceTheme.font(size: 25, weight: .light)).foregroundColor(palette.accent)
                .frame(width: 58, height: 58).background(palette.accent.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(18)))
            Text(model.accounts.isEmpty ? L10n.text("Add your first account") : L10n.text("No matching accounts"))
                .font(appearanceTheme.font(size: 15, weight: .semibold))
            Text(model.accounts.isEmpty ? L10n.text("Personal, work, or study — give each account a recognizable name.") : L10n.text("Try a different name or view all accounts."))
                .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary).multilineTextAlignment(.center)
            if model.accounts.isEmpty {
                Button { model.addAccount() } label: { Label(L10n.text("Get started"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).padding(.top, 3).disabled(model.loadFailed)
            } else {
                Button(L10n.text("View all")) { model.search = ""; model.filter = .all }
                    .buttonStyle(ThemedPlainButtonStyle()).font(appearanceTheme.font(size: 12, weight: .medium)).foregroundColor(palette.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 29).padding(.horizontal, 16)
        .background(palette.surface).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(13)))
        .overlay(RoundedRectangle(cornerRadius: appearanceTheme.radius(13)).stroke(palette.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .retroOutline(radius: appearanceTheme.radius(13))
    }

    private var setupSteps: some View {
        HStack(spacing: 0) {
            step("1", L10n.text("Add profile"), L10n.text("Choose a recognizable name"))
            Spacer()
            Image(systemName: "chevron.right").font(appearanceTheme.font(size: 10)).foregroundColor(palette.line)
            Spacer()
            step("2", L10n.text("Sign in once"), L10n.text("Directly in ChatGPT"))
            Spacer()
            Image(systemName: "chevron.right").font(appearanceTheme.font(size: 10)).foregroundColor(palette.line)
            Spacer()
            step("3", L10n.text("Click to switch"), L10n.text("From the app or menu bar"))
        }.padding(.horizontal, 6)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(appearanceTheme.font(size: 10, weight: .semibold)).foregroundColor(palette.accent)
                .frame(width: 24, height: 24).background(appearanceTheme.isPlayfulRetro ? palette.blue : palette.accent.opacity(0.07)).clipShape(Circle())
                .retroOutline(radius: 100, shadow: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(appearanceTheme.font(size: 10, weight: .medium))
                Text(detail).font(appearanceTheme.font(size: 9)).foregroundColor(palette.secondary)
            }
        }
    }

    private var recoveryBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
            Text(L10n.text("Could not read data. The existing file has been preserved.")).font(appearanceTheme.font(size: 11))
            Spacer()
            Button(L10n.text("Try again")) { model.reload() }
            Button(L10n.text("Open folder")) { model.revealData() }
        }.padding(13).background(appearanceTheme.isPlayfulRetro ? palette.yellow : Color.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(9)))
            .retroOutline(radius: appearanceTheme.radius(9))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(palette.accent).frame(width: 4, height: 4)
            Text(model.lastAction ?? L10n.text("Ready when you are")).lineLimit(1)
            Spacer()
            Text("AI Switcher " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3")).foregroundColor(palette.secondary.opacity(0.7))
        }
        .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
        .padding(.horizontal, 31).frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: appearanceTheme.dividerWidth) }
    }
}

private struct AccountCard: View {
    @Environment(\.appTheme) private var appearanceTheme
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    @ObservedObject var model: AppModel
    let account: Account
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var busy: Bool { model.launchingIDs.contains(account.id) }
    private var running: Bool { model.runningIDs.contains(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Button { model.open(account) } label: { AccountAvatar(account: account) }
                    .buttonStyle(ThemedPlainButtonStyle()).help(L10n.format("Open %@", String(describing: account.name))).disabled(busy)
                Spacer()
                Button { model.toggleFavorite(account) } label: {
                    Image(systemName: account.isFavorite ? "star.fill" : "star")
                        .font(appearanceTheme.font(size: 12)).foregroundColor(appearanceTheme.isPlayfulRetro ? palette.ink : account.isFavorite ? AccountColor.gold.tint(for: appearanceTheme) : palette.secondary.opacity(0.6))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(ThemedPlainButtonStyle()).help(account.isFavorite ? L10n.text("Remove from favorites") : L10n.text("Add to favorites"))
                Menu {
                    Button(L10n.text("Edit profile…")) { model.editor = AccountEditor(account: account) }
                    Button(L10n.text("Codex quota…")) { model.quotaAccountID = account.id }
                    if account.effectiveLaunchMode == .browser {
                        Button(L10n.text("Open a new ChatGPT window")) { model.open(account, newWindow: true) }
                    }
                    Divider()
                    if account.effectiveLaunchMode == .desktop {
                        Button(L10n.text("Connect account session")) { model.connectSession(account) }
                            .disabled(model.quotaBusyIDs.contains(account.id))
                    }
                    Button(L10n.text("Close account session…")) { model.accountToClose = account }.disabled(!running || model.quotaBusyIDs.contains(account.id))
                    Button(L10n.text("Delete local profile…"), role: .destructive) { model.accountToDelete = account }
                        .disabled(model.quotaBusyIDs.contains(account.id) || model.pendingConnections[account.id] != nil)
                } label: { Image(systemName: "ellipsis").font(appearanceTheme.font(size: 13, weight: .medium)).frame(width: 18, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().help(L10n.text("Profile options")).disabled(busy)
            }

            Button { model.open(account) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.name).font(appearanceTheme.font(size: 16, weight: .semibold)).foregroundColor(palette.ink).lineLimit(1)
                    Text(account.emailHint.isEmpty ? L10n.text("Separate ChatGPT profile") : account.emailHint)
                        .font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(ThemedPlainButtonStyle()).disabled(busy)

            HStack(spacing: 5) {
                Image(systemName: account.effectiveLaunchMode == .desktop ? "macwindow" : "globe").font(appearanceTheme.font(size: 10))
                Text(account.effectiveLaunchMode == .desktop ? "ChatGPT Desktop" : account.browser.name).lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
                Circle().fill(running ? palette.accent : palette.secondary.opacity(0.35)).frame(width: 4, height: 4)
                Text(running ? L10n.text("Running") : account.lastOpenedAt == nil ? L10n.text("Not opened yet") : L10n.text("Profile saved")).lineLimit(1).minimumScaleFactor(0.85)
            }.font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)

            QuotaSummaryView(model: model, account: account)

            Button { model.open(account) } label: {
                HStack(spacing: 7) {
                    if busy { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                    Text(busy ? (model.connectingSessionIDs.contains(account.id) ? L10n.text("Connecting session…") : L10n.text("Opening…")) : L10n.text("Open ChatGPT"))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(appearanceTheme.font(size: 10, weight: .semibold))
                }
                .font(appearanceTheme.font(size: 12, weight: .semibold)).foregroundColor(appearanceTheme.isPlayfulRetro ? palette.ink : account.color.tint(for: appearanceTheme))
                .padding(.horizontal, 12).frame(height: 35)
                .background(appearanceTheme.isPlayfulRetro ? palette.surface : account.color.pale(for: appearanceTheme)).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.isPlayfulRetro ? appearanceTheme.buttonRadius : appearanceTheme.radius(7)))
                .retroOutline(radius: appearanceTheme.buttonRadius)
                .contentShape(Rectangle())
            }.buttonStyle(ThemedPlainButtonStyle()).disabled(busy)
                .accessibilityLabel(L10n.format("Open ChatGPT with profile %@", String(describing: account.name)))
        }
        .padding(20).background(appearanceTheme.isPlayfulRetro ? account.color.pale(for: appearanceTheme) : palette.surface).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(13)))
        .overlay(RoundedRectangle(cornerRadius: appearanceTheme.radius(13)).stroke(hovering ? account.color.tint(for: appearanceTheme).opacity(0.4) : palette.line))
        .shadow(color: palette.ink.opacity(hovering ? 0.045 : 0), radius: 10, y: 4)
        .retroOutline(radius: appearanceTheme.radius(13))
        .offset(y: appearanceTheme.isPlayfulRetro && hovering ? -2 : 0)
        .animation(reduceMotion || !appearanceTheme.isPlayfulRetro ? nil : .easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    static let focusAccountSearch = Notification.Name("AISwitcher.focusAccountSearch")
}
