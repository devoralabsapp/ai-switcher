import AppKit
import SwiftUI
import AISwitcherCore

struct AccountEditorView: View {
    private var appearanceTheme: AppTheme { model.preferences.theme }
    private var palette: ThemePalette { ThemePalette(theme: appearanceTheme) }
    @ObservedObject var model: AppModel
    let editor: AccountEditor
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var email: String
    @State private var browser: BrowserKind
    @State private var signInMethod: AccountSignInMethod
    @State private var color: AccountColor
    @State private var sharesLocalWorkspace: Bool
    @State private var openAfterSave: Bool
    @State private var defaultAction: AccountAction
    @State private var connectOnStartup: Bool
    @State private var agent: AIAgent
    @State private var antigravitySignInMethod: AntigravitySignInMethod
    @State private var sharesAntigravityProject: Bool
    @FocusState private var nameFocused: Bool

    init(model: AppModel, editor: AccountEditor) {
        self.model = model
        self.editor = editor
        _name = State(initialValue: editor.account?.name ?? "")
        _email = State(initialValue: editor.account?.emailHint ?? "")
        _browser = State(initialValue: editor.account?.browser ?? editor.defaultBrowser)
        _signInMethod = State(initialValue: editor.account?.effectiveSignInMethod ?? .browser)
        _color = State(initialValue: editor.account?.color ?? editor.defaultColor)
        _sharesLocalWorkspace = State(initialValue: editor.account?.usesSharedLocalWorkspace ?? true)
        _defaultAction = State(initialValue: editor.account?.effectiveDefaultAction ?? (model.preferences.quotaOnlyMode ? .connectSession : .openDesktop))
        _connectOnStartup = State(initialValue: editor.account?.automaticallyConnects ?? false)
        _agent = State(initialValue: editor.account?.effectiveAgent ?? editor.defaultAgent)
        _antigravitySignInMethod = State(initialValue: editor.account?.antigravitySignInMethod ?? .browser)
        _sharesAntigravityProject = State(initialValue: editor.account?.sharesAntigravityProjects ?? false)
        _openAfterSave = State(initialValue: !model.preferences.quotaOnlyMode)
    }

    private var isNew: Bool { editor.account == nil }
    private var canShareAntigravityProject: Bool { agent == .antigravity && (isNew || editor.account?.usesIsolatedAntigravity == true) }
    private var selectedMode: LaunchMode { agent == .chatgpt || agent == .claude ? .desktop : agent.isSharedApplication ? .desktop : .browser }
    private var modeLocked: Bool {
        editor.account.map { model.hasRunningSession($0) || model.launchingIDs.contains($0.id) || model.quotaBusyIDs.contains($0.id) || model.pendingConnections[$0.id] != nil } ?? false
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 48 && email.count <= 160
            && (selectedMode == .desktop || !isNew || model.browserService.applicationURL(for: browser) != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                editorContent.padding(30)
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button { save() } label: { Text(isNew ? L10n.text("Add account") : L10n.text("Save changes")) }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
                    .disabled(!valid).opacity(valid ? 1 : 0.5).accessibilityIdentifier("saveAccount")
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .textFieldStyle(.roundedBorder).foregroundColor(palette.ink)
        .frame(width: 500, height: 740).background(appearanceTheme.isPlayfulRetro ? palette.canvas : palette.surface)
        .appAppearance(model.preferences)
        .onAppear { nameFocused = true }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(isNew ? L10n.text("Another account.\nKeep your flow.") : L10n.text("Edit profile"))
                        .font(appearanceTheme.font(size: 24, weight: .semibold)).tracking(-0.5)
                    Text(isNew ? L10n.text("Choose an AI agent and give its account a recognizable name.") : L10n.text("Names and emails are labels to help you recognize accounts."))
                        .font(appearanceTheme.font(size: 12)).foregroundColor(palette.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(appearanceTheme.font(size: 12, weight: .medium)) }
                    .buttonStyle(ThemedPlainButtonStyle()).foregroundColor(palette.secondary).help(L10n.text("Close"))
            }

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L10n.text("AI agent"), selection: $agent) {
                        ForEach(AIAgent.allCases) { Text($0.name).tag($0) }
                    }.disabled(!isNew).accessibilityIdentifier("accountAgent")
                    Text(agent.supportDetail).font(appearanceTheme.font(size: 11)).foregroundColor(palette.secondary)
                    if !isNew {
                        Text(L10n.text("The agent is fixed for existing profiles. Create another profile to use a different agent."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                    }
                    if agent == .antigravity {
                        Text(L10n.text(editor.account?.usesSharedApplication == true ? "This existing entry keeps the shared Antigravity sign-in. Add another account for a separate session." : "Choose browser sign-in for Google OAuth, or use the official Antigravity CLI. Each account keeps separate sign-in data."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        if isNew {
                            Picker(L10n.text("Sign-in method"), selection: $antigravitySignInMethod) {
                                ForEach(AntigravitySignInMethod.allCases) { Text($0.title).tag($0) }
                            }.accessibilityIdentifier("antigravitySignInMethod")
                            if antigravitySignInMethod == .browser {
                                Text(L10n.text("After Google confirms sign-in, return to AI Switcher and choose Open Antigravity."))
                                    .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                            }
                        }
                        if canShareAntigravityProject {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(L10n.text("Share local project"), isOn: $sharesAntigravityProject)
                                    .accessibilityIdentifier("antigravityShareLocalProject")
                                Text(L10n.text("Share all local projects and conversation history from Antigravity Desktop. Close shared sessions before switching accounts."))
                                    .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                            }
                            .disabled(modeLocked)
                            if modeLocked {
                                Text(L10n.text("Close the session from the ⋯ menu and wait for quota operations to finish before changing modes."))
                                    .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                            }
                        }
                    }
                }
                field(L10n.text("Account name"), detail: L10n.text("For example: Personal, Work, Study")) {
                    TextField(L10n.text("Give this account a name"), text: $name).themedTextField().focused($nameFocused)
                        .accessibilityIdentifier("accountName")
                }
                field(L10n.text("Email or note"), detail: L10n.text("Optional · label only")) {
                    TextField("ban@example.com", text: $email).themedTextField().accessibilityIdentifier("accountEmail")
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("Profile color")).font(appearanceTheme.font(size: 12, weight: .medium))
                    HStack(spacing: 11) {
                        ForEach(AccountColor.allCases) { item in
                            Button { color = item } label: {
                                Circle().fill(appearanceTheme.isPlayfulRetro ? item.pale(for: appearanceTheme) : item.tint(for: appearanceTheme)).frame(width: 27, height: 27)
                                    .overlay { if item == color { Image(systemName: "checkmark").font(appearanceTheme.font(size: 11, weight: .bold)).foregroundColor(appearanceTheme.isPlayfulRetro ? palette.ink : palette.onAccent) } }
                                    .retroOutline(radius: 100, shadow: false)
                                    .padding(3).overlay(Circle().stroke(item == color ? item.tint(for: appearanceTheme).opacity(0.5) : Color.clear, lineWidth: 1))
                            }.buttonStyle(ThemedPlainButtonStyle()).help(item.name).accessibilityLabel(item.name)
                                .accessibilityAddTraits(item == color ? .isSelected : [])
                        }
                    }
                }

                if agent == .chatgpt || agent == .claude {
                    VStack(alignment: .leading, spacing: 9) {
                        Picker(L10n.text("Sign-in Method"), selection: $signInMethod) {
                            ForEach(AccountSignInMethod.allCases) { Text($0.title).tag($0) }
                        }.disabled(modeLocked).accessibilityIdentifier("accountSignInMethod")
                        Text(L10n.text("All sign-in methods open the Desktop app. Each account keeps its own saved session."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        if agent == .claude && signInMethod == .cli {
                            Text(L10n.text("Claude CLI signs in to Claude Code only. Sign in to Claude Desktop once too; quota is read from Desktop, including Free when Claude provides it."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        } else if agent == .claude && signInMethod == .browser {
                            Text(L10n.text("In this account's Claude Desktop window, choose browser sign-in and finish authorization in your browser. The saved session belongs to Desktop."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        } else if agent == .chatgpt && signInMethod == .browser {
                            Text(L10n.text("Authorize in your existing Chrome, then return to this account's ChatGPT Desktop session."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        }
                        if !isNew {
                            Text(L10n.text("To sign in again, close the session, then choose Sign in… in the account menu."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        }
                        if editor.account?.effectiveLaunchMode == .browser {
                            Text(L10n.text("Existing browser sign-ins stay saved. Sign in once for the new Desktop session."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        }
                        if modeLocked {
                            Text(L10n.text("Close the session from the ⋯ menu and wait for quota operations to finish before changing modes."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        }
                    }
                }

                if agent == .chatgpt {
                VStack(alignment: .leading, spacing: 9) {
                        Picker(L10n.text("Default account action"), selection: $defaultAction) {
                            ForEach(AccountAction.allCases) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("defaultAccountAction")
                        if model.preferences.quotaOnlyMode {
                            Text(L10n.text("Quota-only mode currently overrides this action to Connect in background."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        }
                        Toggle(L10n.text("Connect in background when AI Switcher starts"), isOn: $connectOnStartup)
                            .toggleStyle(.checkbox).font(appearanceTheme.font(size: 11))
                            .accessibilityIdentifier("connectOnStartup")
                        Text(L10n.text("Uses the saved sign-in without opening Desktop. Sign in once first using Open ChatGPT."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                        Toggle(L10n.text("Share local projects and Work history"), isOn: $sharesLocalWorkspace)
                            .toggleStyle(.checkbox).font(appearanceTheme.font(size: 11))
                            .disabled(modeLocked)
                        if sharesLocalWorkspace {
                            Text(L10n.text("Use this Mac's existing ChatGPT projects and local history. Each profile keeps its own sign-in; cloud chats belong to the signed-in account."))
                                .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(L10n.text("Each account has a separate ChatGPT Desktop session and backend. Sign in once in its window. Requires the new ChatGPT with Chat, Work, and Codex; app updates may affect this experimental mode."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary).fixedSize(horizontal: false, vertical: true)

                }

                }

                if selectedMode == .browser {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("Browser that keeps this login")).font(appearanceTheme.font(size: 12, weight: .medium))
                    if isNew {
                        Picker(L10n.text("Browser"), selection: $browser) {
                            ForEach(BrowserKind.allCases) { item in
                                Text(item.name + (model.browserService.applicationURL(for: item) == nil ? L10n.text(" · not installed") : "")).tag(item)
                            }
                        }.labelsHidden().frame(maxWidth: .infinity).controlSize(.large)
                    } else {
                        Label(browser.name, systemImage: "globe").font(appearanceTheme.font(size: 12)).foregroundColor(palette.secondary)
                        Text(L10n.text("This profile keeps its original browser to preserve its login."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                    }
                    if isNew && model.browserService.applicationURL(for: browser) == nil {
                        HStack {
                            Text(L10n.format("Install %@ before adding a profile.", String(describing: browser.name))).font(appearanceTheme.font(size: 11)).foregroundColor(.orange)
                            Button(L10n.text("Download browser")) { openBrowserDownload() }.font(appearanceTheme.font(size: 11))
                        }
                    }
                }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").foregroundColor(palette.accent)
                Text(agent == .claude ? L10n.text("Claude quota reads only this profile's Desktop session cookie to request account and usage data from claude.ai. It does not read conversations or copy cookies into account metadata or logs. macOS may ask for Keychain access.") : agent == .chatgpt ? L10n.text("Sign in directly in ChatGPT. AI Switcher does not read passwords, cookies, or conversations. Quota comes from this session's Codex backend.") : L10n.text("Sign in directly with the selected agent. AI Switcher does not read passwords, cookies, or conversations."))
                    .font(appearanceTheme.font(size: 11)).lineSpacing(4).foregroundColor(palette.secondary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(appearanceTheme.isPlayfulRetro ? palette.mint : palette.accent.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(9)))
                .retroOutline(radius: appearanceTheme.radius(9), shadow: false)

            if isNew {
                Toggle(agent == .antigravity || agent == .chatgpt || agent == .claude ? L10n.text("Sign in after adding") : L10n.format("Open %@ after adding", agent.name), isOn: $openAfterSave)
                    .toggleStyle(.checkbox).font(appearanceTheme.font(size: 12))
            }


        }
    }

    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(appearanceTheme.font(size: 12, weight: .medium))
                Spacer()
                Text(detail).font(appearanceTheme.font(size: 9)).foregroundColor(palette.secondary)
            }
            content().font(appearanceTheme.font(size: 13)).controlSize(.large)
        }
    }

    private func save() {
        var account = editor.account ?? Account(name: name, browser: browser, color: color)
        account.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.emailHint = email.trimmingCharacters(in: .whitespacesAndNewlines)
        account.color = color
        account.launchMode = selectedMode
        if agent == .chatgpt || agent == .claude {
            account.signInMethod = signInMethod
            if isNew || editor.account?.effectiveLaunchMode == .browser { account.desktopSignInPending = true }
        }
        account.agent = agent
        if isNew && agent == .antigravity { account.antigravityUsesPrivateHome = true }
        if isNew && agent == .antigravity {
            account.antigravitySignInMethod = antigravitySignInMethod
        }
        if canShareAntigravityProject {
            account.antigravitySharesLocalProjects = sharesAntigravityProject
            account.antigravityLocalProjectFolder = nil
        }
        account.sharesLocalWorkspace = agent == .chatgpt && sharesLocalWorkspace
        account.defaultAction = agent == .chatgpt ? defaultAction : .openDesktop
        account.connectOnStartup = agent == .chatgpt && connectOnStartup
        // Label edits on an active legacy web session must not move its storage.
        if let original = editor.account, original.supportsDesktopSignIn,
           original.effectiveLaunchMode == .browser, modeLocked {
            account.launchMode = original.launchMode
            account.signInMethod = original.signInMethod
            account.desktopSignInPending = original.desktopSignInPending
            account.sharesLocalWorkspace = original.sharesLocalWorkspace
        }
        guard model.saveAccount(account) else { return }
        dismiss()
        if isNew && openAfterSave {
            if agent == .antigravity { model.connectSession(account) }
            else if account.supportsDesktopSignIn { model.signInAccount(account) }
            else { model.open(account) }
        }
    }

    private func openBrowserDownload() {
        let address: String
        switch browser {
        case .chrome: address = "https://www.google.com/chrome/"
        case .edge: address = "https://www.microsoft.com/edge/download"
        case .brave: address = "https://brave.com/download/"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
