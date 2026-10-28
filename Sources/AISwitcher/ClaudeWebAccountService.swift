import AppKit
import WebKit
import CryptoKit
import AISwitcherCore

/// Owns a separate website data store per profile. No Desktop cookies or CLI credentials are imported.
@MainActor
final class ClaudeWebAccountService {
    let repository: ProfileRepository
    private var sessions: [UUID: Session] = [:]
    init(repository: ProfileRepository) { self.repository = repository }
    static func storeIdentifier(root: URL, accountID: UUID) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("aisw-claude-web-v1\n" + root.standardizedFileURL.path + "\n" + accountID.uuidString).utf8)))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func session(_ account: Account) -> Session {
        if let value = sessions[account.id] { return value }
        let store: WKWebsiteDataStore
        if #available(macOS 14.0, *) { store = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(root: repository.root, accountID: account.id)) }
        else { store = .nonPersistent() }
        let value = Session(store: store);sessions[account.id] = value;return value
    }
    func read(_ account: Account, interactive: Bool = false, onSignIn: () -> Void = {}, onIdentity: ((CodexIdentity) throws -> Void)? = nil) async throws -> CodexConnection {
        let session = session(account);session.cancelled = false
        if session.webView.url == nil || session.webView.url?.scheme == "about" { session.load() }
        let deadline = Date().addingTimeInterval(interactive ? 300 : 25)
        var showedLogin = false
        let started = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            if session.cancelled { throw CancellationError() }
            if session.webView.isLoading || session.webView.url == nil {
                if interactive && !showedLogin && Date().timeIntervalSince(started) > 2 { showedLogin = true;onSignIn();session.show(name: account.name) }
                try await Task.sleep(nanoseconds: 300_000_000);continue
            }
            if session.webView.url?.host == "claude.ai", session.webView.url?.scheme == "https" {
                do {
                    let raw = try await session.webView.callAsyncJavaScript(try ClaudeWebAccount.probeScript, arguments: [:], in: nil, contentWorld: .page)
                    try Task.checkCancellation()
                    guard let text = raw as? String, text.utf8.count < 65_536 else { throw ProviderQuotaError.invalidResponse }
                    let metadata = try ClaudeWebAccount.parse(Data(text.utf8), emailHint: account.emailHint)
                    try onIdentity?(metadata.identity)
                    session.closeWindows()
                    var quota: CodexQuotaSnapshot?
                    if metadata.identity.planType != "free", let org = metadata.organizationID {
                        if let result = try? await session.webView.callAsyncJavaScript(try ClaudeWebAccount.usageScript, arguments: ["organizationID": org], in: nil, contentWorld: .page),
                           let text = result as? String, text.utf8.count < 65_536 {
                            quota = try? ProviderQuotaParser.parse(Data(text.utf8), agent: .claude, identity: metadata.identity).quota
                        }
                    }
                    try Task.checkCancellation()
                    if metadata.identity.planType != "free", quota == nil { throw ProviderQuotaError.unavailable }
                    return CodexConnection(identity: metadata.identity, quota: quota, identityFetchedAt: Date(), providerSessionKind: "claudeWeb")
                } catch ProviderQuotaError.signedOut { try Task.checkCancellation();if session.cancelled { throw CancellationError() } }
                catch ProviderQuotaError.identityChanged {
                    try Task.checkCancellation();if session.cancelled { throw CancellationError() }
                    guard interactive else { throw ProviderQuotaError.identityChanged }
                }
                catch let error as ProviderQuotaError { try Task.checkCancellation();if session.cancelled { throw CancellationError() };throw error }
                catch { try Task.checkCancellation();if session.cancelled { throw CancellationError() };throw ProviderQuotaError.unavailable }
            }
            guard interactive else { throw ProviderQuotaError.signedOut }
            if !showedLogin { showedLogin = true;onSignIn();session.show(name: account.name) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ProviderQuotaError.timeout
    }
    func stop(_ id: UUID) { sessions[id]?.stop() }
    func stopAll() { for value in sessions.values { value.stop() } }
    func remove(_ account: Account) async {
        if let value = sessions.removeValue(forKey: account.id) {
            value.stop()
            await value.webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        if #available(macOS 14.0, *) { try? await WKWebsiteDataStore.remove(forIdentifier: Self.storeIdentifier(root: repository.root, accountID: account.id)) }
    }

    @MainActor
    private final class Session: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
        let webView: WKWebView
        var cancelled = false
        private var loginWindow: NSWindow?
        private var popupWindows: [NSWindow] = []
        init(store: WKWebsiteDataStore) {
            let config = WKWebViewConfiguration();config.websiteDataStore = store
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 840, height: 720), configuration: config)
            super.init();webView.navigationDelegate = self;webView.uiDelegate = self
        }
        func load() { webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/profile")!)) }
        func show(name: String) {
            if loginWindow == nil {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.title = L10n.format("Sign in to Claude — %@", name);window.isReleasedWhenClosed = false
                window.contentView = webView;window.delegate = self;window.center();loginWindow = window
            }
            loginWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps: true)
        }
        func closeWindows() {
            loginWindow?.delegate = nil;loginWindow?.contentView = nil;loginWindow?.close();loginWindow = nil
            for popup in popupWindows { popup.delegate = nil;popup.close() };popupWindows.removeAll()
        }
        func stop() {
            cancelled = true
            webView.evaluateJavaScript("globalThis.__aiswAccountProbeController?.abort(); globalThis.__aiswUsageProbeController?.abort();", completionHandler: nil)
            webView.stopLoading();closeWindows();webView.loadHTMLString("", baseURL: nil)
        }
        func windowWillClose(_ notification: Notification) { if (notification.object as? NSWindow) === loginWindow { cancelled = true } }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.scheme == "https" || url.absoluteString == "about:blank" else { decisionHandler(.cancel);return }
            if let host = url.host, navigationAction.targetFrame?.isMainFrame != false {
                let window = webView === self.webView ? loginWindow : popupWindows.first { $0.contentView === webView }
                window?.title = L10n.format("Sign in — %@", host)
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url, url.scheme == "https" || url.absoluteString == "about:blank" else { return nil }
            let child = WKWebView(frame: webView.bounds, configuration: configuration);child.navigationDelegate = self;child.uiDelegate = self
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("Sign in to Claude");window.isReleasedWhenClosed = false;window.contentView = child;window.center();window.makeKeyAndOrderFront(nil);popupWindows.append(window)
            return child
        }
        func webViewDidClose(_ webView: WKWebView) {
            if let window = popupWindows.first(where: { $0.contentView === webView }) { window.close();popupWindows.removeAll { $0 === window } }
        }
    }
}
