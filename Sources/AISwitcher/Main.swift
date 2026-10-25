import AppKit
import SwiftUI
import Combine
import AISwitcherCore
import Darwin

@main
struct AISwitcherMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--quota-socket-bridge" {
            do { try LocalWebSocket.run(socketPath: CommandLine.arguments[2]); Darwin.exit(0) }
            catch { Darwin.exit(1) }
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var noticeSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let root: URL
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AI Switcher", isDirectory: true)
        }
        model = AppModel(root: root)
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let icon = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: "AI Switcher")
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "AI Switcher — chuyển tài khoản ChatGPT"
        }
        rebuildStatusMenu()
        subscription = model.$snapshot.combineLatest(model.$runningIDs, model.$launchingIDs, model.$quotaErrors)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildStatusMenu() }
        noticeSubscription = model.$notice.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showDashboard() }

        if arguments.contains("--desktop-smoke-test") {
            Task { await desktopSmokeTest(root: root) }
        } else if arguments.contains("--quota-smoke-test") {
            Task { await quotaSmokeTest(root: root) }
        } else if arguments.contains("--smoke-test") {
            Task { await smokeTest(root: root) }
        } else {
            showDashboard()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdownQuota()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    @objc private func showDashboard() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "AI Switcher"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .white
            window.minSize = NSSize(width: 900, height: 670)
            window.contentView = NSHostingView(rootView: Dashboard(model: model))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("AISwitcher.Dashboard")
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func addAccount() { showDashboard(); model.addAccount() }
    @objc private func showGuide() { showDashboard(); model.showGuide = true }
    @objc private func revealData() { model.revealData() }
    @objc private func focusSearch() {
        showDashboard()
        NotificationCenter.default.post(name: .focusAccountSearch, object: nil)
    }

    @objc private func openAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let account = model.accounts.first(where: { $0.id == id }) else { return }
        model.open(account)
    }

    @objc private func openLastAccount() {
        if let account = model.lastOpened { model.open(account) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshRunning()
        for item in menu.items {
            if let id = item.representedObject as? UUID, let account = model.accounts.first(where: { $0.id == id }) {
                item.title = statusTitle(account)
            }
        }
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu(title: "AI Switcher")
        menu.autoenablesItems = false
        menu.delegate = self
        let title = NSMenuItem(title: "CHỌN TÀI KHOẢN CHATGPT", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if model.accounts.isEmpty {
            let empty = NSMenuItem(title: "Thêm tài khoản để bắt đầu", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for account in model.menuAccounts {
            let busy = model.launchingIDs.contains(account.id)
            let item = NSMenuItem(title: statusTitle(account),
                                  action: #selector(openAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            item.isEnabled = !busy
            item.state = model.snapshot.lastOpenedID == account.id ? .on : .off
            item.image = NSImage(systemSymbolName: account.isFavorite ? "star.fill" : "person.crop.circle", accessibilityDescription: nil)
            item.toolTip = "Mở hồ sơ \(account.name) bằng \(account.effectiveLaunchMode == .desktop ? "ChatGPT Desktop" : account.browser.name)"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem("Thêm tài khoản…", action: #selector(addAccount), to: menu)
        addItem("Quản lý tài khoản…", action: #selector(showDashboard), to: menu)
        menu.addItem(.separator())
        addItem("Thoát AI Switcher", action: #selector(quit), to: menu)
        statusItem?.menu = menu
        statusItem?.button?.toolTip = model.lastOpened.map { "AI Switcher — dùng gần nhất: \($0.name)" }
            ?? "AI Switcher — chuyển tài khoản ChatGPT"
        rebuildAccountMenu()
    }

    private func statusTitle(_ account: Account) -> String {
        let suffix = account.emailHint.isEmpty ? "" : "  ·  \(account.emailHint)"
        var quotaLabel = ""
        if let quota = account.displayedCodexConnection?.quota {
            if quota.isStale(at: Date()) || model.quotaErrors[account.id] != nil { quotaLabel = "  ·  Codex: dữ liệu cũ" }
            else if let bucket = quota.limits.buckets.first {
                let windows = [bucket.value.primary, bucket.value.secondary].compactMap { $0 }.compactMap { window -> String? in
                    guard let remaining = window.remainingPercent else { return nil }
                    return "\(window.durationLabel) \(Int(remaining.rounded()))%"
                }
                let name = bucket.id == "codex" ? "Codex" : (bucket.value.limitName ?? bucket.id)
                if !windows.isEmpty { quotaLabel = "  ·  \(name) còn: " + windows.joined(separator: " / ") }
            }
        }
        return account.name + suffix + quotaLabel + (model.launchingIDs.contains(account.id) ? "  (đang mở…)" : "")
    }

    private var accountMenu: NSMenu?

    private func buildMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "AI Switcher")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        addItem("Về AI Switcher", action: #selector(showGuide), to: appMenu)
        appMenu.addItem(.separator())
        addItem("Quản lý tài khoản", action: #selector(showDashboard), key: "0", to: appMenu)
        addItem("Thêm tài khoản…", action: #selector(addAccount), key: "n", to: appMenu)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Ẩn AI Switcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        addItem("Thoát AI Switcher", action: #selector(quit), key: "q", to: appMenu)

        let editMenu = NSMenu(title: "Chỉnh sửa")
        let editItem = NSMenuItem(title: "Chỉnh sửa", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        for (title, selector, key) in [
            ("Hoàn tác", Selector(("undo:")), "z"),
            ("Cắt", #selector(NSText.cut(_:)), "x"),
            ("Sao chép", #selector(NSText.copy(_:)), "c"),
            ("Dán", #selector(NSText.paste(_:)), "v"),
            ("Chọn tất cả", #selector(NSText.selectAll(_:)), "a"),
        ] { editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        editMenu.addItem(.separator())
        addItem("Tìm tài khoản", action: #selector(focusSearch), key: "k", to: editMenu)
        main.addItem(editItem)

        let accounts = NSMenu(title: "Tài khoản")
        accounts.autoenablesItems = false
        let accountsItem = NSMenuItem(title: "Tài khoản", action: nil, keyEquivalent: "")
        accountsItem.submenu = accounts
        main.addItem(accountsItem)
        accountMenu = accounts

        let windowMenu = NSMenu(title: "Cửa sổ")
        let windowItem = NSMenuItem(title: "Cửa sổ", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Thu nhỏ", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Đóng cửa sổ", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func rebuildAccountMenu() {
        guard let menu = accountMenu else { return }
        menu.removeAllItems()
        for (index, account) in model.accounts.enumerated() {
            let item = NSMenuItem(title: account.name, action: #selector(openAccount(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.representedObject = account.id
            item.target = self
            item.isEnabled = !model.launchingIDs.contains(account.id)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem("Mở tài khoản gần nhất", action: #selector(openLastAccount), to: menu)
        addItem("Thêm tài khoản…", action: #selector(addAccount), to: menu)
    }

    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    /// Uses two new, disposable Desktop profiles; never signs in or reads existing credentials.
    private func desktopSmokeTest(root: URL) async {
        setbuf(stdout, nil)
        guard CommandLine.arguments.contains("--data-dir"), root.lastPathComponent.hasPrefix("ai-switcher-smoke."),
              model.accounts.isEmpty else {
            fputs("FAIL: a new ai-switcher-smoke.* data directory is required\n", stderr)
            Darwin.exit(1)
        }
        let service = model.desktopService, repository = model.repository
        let a = Account(name: "Desktop Smoke A", launchMode: .desktop)
        let b = Account(name: "Desktop Smoke B", launchMode: .desktop)
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopLaunch.bundleIdentifier)
        var failure: Error?
        do {
            let installed = try service.installation()
            print("Testing ChatGPT Desktop \(installed.version)")
            let first = try await service.open(a)
            print("Opened isolated Desktop A")
            let second = try await service.open(b)
            guard first.processIdentifier != second.processIdentifier,
                  !existing.contains(where: { [first.processIdentifier, second.processIdentifier].contains($0.processIdentifier) }) else {
                throw DesktopProfileError.launchFailed
            }
            print("PASS: two real Desktop processes, separate from existing application instances")
            for account in [a, b] {
                let client = try service.quotaClient(account.id)
                do {
                    try await client.start()
                    do {
                        _ = try await client.readIdentity()
                        throw CodexQuotaError.identityChanged
                    } catch CodexQuotaError.notSignedIn { }
                    await client.stop()
                } catch { await client.stop(); throw error }
            }
            print("PASS: both Desktop backends have no inherited account; quota bridge handshake works")
            let windows = ManagedApplications.windowCount(first)
            let reused = try await service.open(a)
            guard reused.processIdentifier == first.processIdentifier,
                  ManagedApplications.windowCount(first) == windows else { throw DesktopProfileError.launchFailed }
            print("PASS: switching targets the existing profile process and reuses its window")
            let marker = repository.desktopUserDataURL(for: a.id).appendingPathComponent("ai-switcher-smoke-fixture")
            try Data("retained-profile".utf8).write(to: marker)
            try await service.close(a)
            guard !second.isTerminated, existing.allSatisfy({ !$0.isTerminated }) else { throw DesktopProfileError.launchFailed }
            let reopened = try await service.open(a)
            guard reopened.processIdentifier != first.processIdentifier,
                  try String(contentsOf: marker) == "retained-profile" else { throw DesktopProfileError.launchFailed }
            print("PASS: closing/reopening preserves profile data; other Desktop instances remain running")
        } catch { failure = error }
        for account in [a, b] {
            do {
                try await service.close(account)
                _ = try repository.remove(account.id, from: AccountSnapshot())
            } catch { failure = failure ?? error }
        }
        if let failure {
            fputs("FAIL: \(failure.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
        print("PASS: disposable Desktop processes, daemons and storage cleaned up")
        Darwin.exit(0)
    }

    /// Uses a throwaway Codex home only; never touches user accounts.
    private func quotaSmokeTest(root: URL) async {
        guard let executable = model.quotaService.executableURL,
              CommandLine.arguments.contains("--data-dir") else {
            fputs("FAIL: isolated --data-dir and an installed Codex CLI are required\n", stderr)
            Darwin.exit(1)
        }
        do {
            let home = try model.repository.prepareCodexHome(for: UUID())
            let client = CodexRPCClient(executable: executable, home: home)
            do {
                try await client.start()
                do {
                    _ = try await client.readIdentity()
                    throw CodexQuotaError.identityChanged
                } catch CodexQuotaError.notSignedIn {
                    print("PASS: installed Codex app-server handshake; isolated home has no inherited account")
                }
                await client.stop()
            } catch { await client.stop(); throw error }
            print("PASS: quota helper stopped; no login or model request was performed")
            Darwin.exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }

    /// Uses throwaway browser profiles only; never touches user accounts.
    private func smokeTest(root: URL) async {
        let a = Account(name: "Smoke A"), b = Account(name: "Smoke B")
        let fixture = root.appendingPathComponent("fixture.html")
        var failure: Error?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "<title>AI Switcher Test</title><h1>Isolated profile smoke test</h1>".write(to: fixture, atomically: true, encoding: .utf8)
            let first = try await model.browserService.open(a, url: fixture)
            let second = try await model.browserService.open(b, url: fixture)
            guard first.processIdentifier != second.processIdentifier else { throw ProfileError.browserLaunchFailed }
            let count = model.browserService.windowCount(for: first)
            let reused = try await model.browserService.open(a, url: fixture)
            guard reused.processIdentifier == first.processIdentifier,
                  model.browserService.windowCount(for: first) == count else { throw ProfileError.browserLaunchFailed }
            print("PASS: separate profile PIDs; exact profile routing; switching reuses existing window")
        } catch { failure = error }
        for account in [a, b] {
            do { try await model.browserService.close(account) }
            catch { failure = failure ?? error }
        }
        if let failure {
            fputs("FAIL: \(failure.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
        print("PASS: dedicated test sessions closed without touching other browser profiles")
        Darwin.exit(0)
    }
}
