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
    @State private var launchMode: LaunchMode
    @State private var color: AccountColor
    @State private var sharesLocalWorkspace: Bool
    @State private var openAfterSave = true
    @FocusState private var nameFocused: Bool

    init(model: AppModel, editor: AccountEditor) {
        self.model = model
        self.editor = editor
        _name = State(initialValue: editor.account?.name ?? "")
        _email = State(initialValue: editor.account?.emailHint ?? "")
        _browser = State(initialValue: editor.account?.browser ?? editor.defaultBrowser)
        _launchMode = State(initialValue: editor.account?.effectiveLaunchMode ?? .desktop)
        _color = State(initialValue: editor.account?.color ?? editor.defaultColor)
        _sharesLocalWorkspace = State(initialValue: editor.account?.usesSharedLocalWorkspace ?? true)
    }

    private var isNew: Bool { editor.account == nil }
    private var modeLocked: Bool {
        editor.account.map { model.hasRunningSession($0) || model.launchingIDs.contains($0.id) || model.quotaBusyIDs.contains($0.id) || model.pendingConnections[$0.id] != nil } ?? false
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 48 && email.count <= 160
            && (launchMode == .desktop || !isNew || model.browserService.applicationURL(for: browser) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(isNew ? L10n.text("Another account.\nKeep your flow.") : L10n.text("Edit profile"))
                        .font(appearanceTheme.font(size: 24, weight: .semibold)).tracking(-0.5)
                    Text(isNew ? L10n.text("Create a separate space for your ChatGPT account.") : L10n.text("Names and emails are labels to help you recognize accounts."))
                        .font(appearanceTheme.font(size: 12)).foregroundColor(palette.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(appearanceTheme.font(size: 12, weight: .medium)) }
                    .buttonStyle(ThemedPlainButtonStyle()).foregroundColor(palette.secondary).help(L10n.text("Close"))
            }

            VStack(alignment: .leading, spacing: 18) {
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

                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("Open accounts with")).font(appearanceTheme.font(size: 12, weight: .medium))
                    Picker(L10n.text("Mode"), selection: $launchMode) {
                        ForEach(LaunchMode.allCases) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                        .disabled(modeLocked)
                    if modeLocked {
                        Text(L10n.text("Close the session from the ⋯ menu and wait for quota operations to finish before changing modes."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                    }
                    if launchMode == .desktop {
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
                    } else {
                        Text(L10n.text("Browser mode keeps its previous session separate. Close the session from the ⋯ menu before changing modes."))
                            .font(appearanceTheme.font(size: 10)).foregroundColor(palette.secondary)
                    }
                }

                if launchMode == .browser {
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
                Text(L10n.text("Sign in directly in ChatGPT. AI Switcher does not read passwords, cookies, or conversations. Quota comes from this session's Codex backend."))
                    .font(appearanceTheme.font(size: 11)).lineSpacing(4).foregroundColor(palette.secondary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(appearanceTheme.isPlayfulRetro ? palette.mint : palette.accent.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: appearanceTheme.radius(9)))
                .retroOutline(radius: appearanceTheme.radius(9), shadow: false)

            if isNew {
                Toggle(L10n.text("Open ChatGPT to sign in after adding"), isOn: $openAfterSave)
                    .toggleStyle(.checkbox).font(appearanceTheme.font(size: 12))
            }

            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button { save() } label: { Text(isNew ? L10n.text("Add account") : L10n.text("Save changes")) }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
                    .disabled(!valid).opacity(valid ? 1 : 0.5).accessibilityIdentifier("saveAccount")
            }
        }
        .textFieldStyle(.roundedBorder).foregroundColor(palette.ink)
        .padding(30).frame(width: 500).background(appearanceTheme.isPlayfulRetro ? palette.canvas : palette.surface)
        .appAppearance(model.preferences)

        .onAppear { nameFocused = true }
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
        account.launchMode = launchMode
        account.sharesLocalWorkspace = sharesLocalWorkspace
        guard model.saveAccount(account) else { return }
        dismiss()
        if isNew && openAfterSave { model.open(account) }
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
