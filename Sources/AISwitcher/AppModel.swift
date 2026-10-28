import AppKit
import AISwitcherCore
import Combine

enum AccountFilter: String, CaseIterable {
    case all, favorites, recent

    var title: String {
        switch self {
        case .all: return L10n.text("All accounts")
        case .favorites: return L10n.text("Favorites")
        case .recent: return L10n.text("Recent")
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "star"
        case .recent: return "clock.arrow.circlepath"
        }
    }
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = AccountSnapshot()
    @Published var filter: AccountFilter = .all
    @Published var search = ""
    @Published var editor: AccountEditor?
    @Published var notice: AppNotice?
    @Published var accountToDelete: Account?
    @Published var accountToClose: Account?
    @Published var accountToRestart: Account?
    @Published var showDiagnostics = false
    @Published private(set) var desktopCompatibility: DesktopCompatibility?
    @Published private(set) var diagnosticStorageErrors: [UUID: String] = [:]
    @Published private(set) var lastQuotaChecks: [UUID: Date] = [:]
    @Published private(set) var notificationPermission: QuotaNotificationPermission = .notRequested
    @Published private(set) var notificationSettingsBusy = false
    @Published private(set) var notificationError: String?
    @Published var showGuide = false
    @Published var showPreferences = false
    @Published private(set) var preferences = AppPreferences()
    @Published private(set) var launchingIDs: Set<UUID> = []
    @Published private(set) var connectingSessionIDs: Set<UUID> = []
    @Published private(set) var closingSessionIDs: Set<UUID> = []
    @Published private(set) var desktopWindowIDs: Set<UUID> = []
    @Published private(set) var providerSessionIDs: Set<UUID> = []
    @Published private(set) var providerSignInIDs: Set<UUID> = []
    private lazy var providerQuota = ProviderQuotaService(repository: repository)
    private lazy var claudeWeb = ClaudeWebAccountService(repository: repository)
    @Published private(set) var installingProviderAgents: Set<AIAgent> = []
    @Published private(set) var providerInstallationErrors: [AIAgent: String] = [:]
    private var providerInstallationTasks: [AIAgent: Task<Void, Never>] = [:]
    private var webCleanupTasks: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var backendIDs: Set<UUID> = []
    @Published private(set) var runningIDs: Set<UUID> = []
    @Published private(set) var loadFailed = false
    @Published private(set) var lastAction: String?
    @Published var quotaAccountID: UUID?
    @Published private(set) var quotaBusyIDs: Set<UUID> = []
    @Published private(set) var quotaErrors: [UUID: Error] = [:]
    @Published private(set) var pendingConnections: [UUID: CodexConnection] = [:]
    @Published private(set) var connectingID: UUID?

    let repository: ProfileRepository
    let browserService: BrowserService
    let claudeDesktopService: ClaudeDesktopService
    let desktopService: DesktopService
    let quotaService: CodexQuotaService
    let agentApplications = AgentApplicationService()
    private let desktopQuotaSource: any DesktopQuotaSource
    private var refreshTimer: AnyCancellable?
    private var quotaTimer: AnyCancellable?
    private var quotaTasks: [UUID: Task<Void, Never>] = [:]
    private var quotaSweepTask: Task<Void, Never>?
    private var quotaCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var desktopQuotaClients: [UUID: CodexRPCClient] = [:]
    private var desktopQuotaRetryAt: [UUID: Date] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var startupTask: Task<Void, Never>?
    private var didConnectStartupAccounts = false
    private var shuttingDown = false
    private let preferencesStore: AppPreferencesStore
    private let notifications: any QuotaNotificationSending
    private var quotaAlertTracker: QuotaAlertTracker

    init(root: URL, preferences: AppPreferences? = nil, monitoring: Bool = true,
         desktopQuotaSource: (any DesktopQuotaSource)? = nil,
         preferencesStore: AppPreferencesStore = AppPreferencesStore(),
         notifications: (any QuotaNotificationSending)? = nil) {
        self.preferencesStore = preferencesStore
        self.notifications = notifications ?? QuotaNotificationService()
        quotaAlertTracker = preferencesStore.loadAlertTracker()
        self.preferences = preferences ?? preferencesStore.load()
        repository = ProfileRepository(root: root)
        browserService = BrowserService(repository: repository)
        desktopService = DesktopService(repository: repository)
        claudeDesktopService = ClaudeDesktopService(repository: repository)
        self.desktopQuotaSource = desktopQuotaSource ?? desktopService
        quotaService = CodexQuotaService(repository: repository)
        reload()
        guard monitoring else { return }
        refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshRunning()
            self?.refreshDesktopQuotaIfNeeded()
        }
        quotaTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshAllQuotas()
        }
        startupTask = Task { [weak self] in
            await self?.connectStartupAccounts()
            if !Task.isCancelled { self?.refreshAllQuotas() }
        }
    }

    var accounts: [Account] { snapshot.accounts }
    var lastOpened: Account? { accounts.first { $0.id == snapshot.lastOpenedID } }

    func setLanguage(_ language: AppLanguage) {
        var updated = preferences
        updated.language = language
        preferencesStore.save(updated)
        lastAction = nil
        preferences = updated
    }

    func setTheme(_ theme: AppTheme) {
        var updated = preferences
        updated.theme = theme
        preferencesStore.save(updated)
        preferences = updated
    }

    func setQuotaOnlyMode(_ enabled: Bool) {
        var updated = preferences
        updated.quotaOnlyMode = enabled
        updated.workspaceLayout = enabled ? .quotaTable : .cards
        savePreferences(updated)
    }

    func setWorkspaceLayout(_ layout: WorkspaceLayout) {
        var updated = preferences
        updated.workspaceLayout = layout
        savePreferences(updated)
    }

    func setAgentFilter(_ agent: AIAgent?) {
        var updated = preferences
        updated.agentFilter = agent
        savePreferences(updated)
    }

    func agentCount(_ agent: AIAgent?) -> Int {
        accounts.filter { agent == nil || $0.effectiveAgent == agent }.count
    }

    func setQuotaSort(_ key: QuotaSortKey) {
        var updated = preferences
        updated.quotaSortAscending = key == updated.quotaSortKey ? !updated.quotaSortAscending : key != .lastUpdated
        updated.quotaSortKey = key
        savePreferences(updated)
    }

    private func savePreferences(_ updated: AppPreferences) {
        preferencesStore.save(updated)
        preferences = updated
    }

    func refreshNotificationPermission() async {
        notificationPermission = await notifications.permission()
    }

    func setQuotaNotifications(_ enabled: Bool) async {
        guard !notificationSettingsBusy else { return }
        notificationSettingsBusy = true
        notificationError = nil
        defer { notificationSettingsBusy = false }
        var updated = preferences
        if enabled {
            do {
                let permission = await notifications.permission()
                let granted: Bool
                if permission == .notRequested { granted = try await notifications.requestPermission() }
                else { granted = permission == .allowed }
                notificationPermission = await notifications.permission()
                guard granted else { return }
            } catch {
                notificationError = L10n.text("Could not enable notifications. Try again from the packaged app.")
                return
            }
        }
        // Re-read after the permission prompt so unrelated settings are preserved.
        updated = preferences
        if updated.quotaAlerts.enabled != enabled {
            quotaAlertTracker = .init()
            preferencesStore.saveAlertTracker(quotaAlertTracker)
        }
        updated.quotaAlerts.enabled = enabled
        savePreferences(updated)
        if !enabled { notifications.clearPending() }
    }

    func setQuotaAlertThreshold(_ threshold: Int) {
        var updated = preferences
        updated.quotaAlerts.threshold = min(95, max(1, threshold))
        savePreferences(updated)
    }

    func setQuotaRecoveryAlerts(_ enabled: Bool) {
        var updated = preferences
        updated.quotaAlerts.notifyRecovery = enabled
        savePreferences(updated)
    }

    private func notifyQuota(_ id: UUID) async {
        guard !shuttingDown, preferences.quotaAlerts.enabled,
              let account = accounts.first(where: { $0.id == id }), let quota = account.displayedCodexConnection?.quota else { return }
        notificationPermission = await notifications.permission()
        guard notificationPermission == .allowed, preferences.quotaAlerts.enabled, !shuttingDown else { return }
        var next = quotaAlertTracker
        next.retainAccounts(Set(accounts.map(\.id)))
        let events = next.evaluate(account: account, snapshot: quota, settings: preferences.quotaAlerts)
        // Reserve transitions before delivery so simultaneous account reads cannot
        // overwrite one another or send the same transition twice.
        quotaAlertTracker = next
        preferencesStore.saveAlertTracker(next)
        do {
            if !events.isEmpty { try await notifications.send(events, accountName: account.name, sound: false) }
        } catch { notificationError = L10n.text("A quota notification could not be delivered. Check macOS notification settings.") }
    }

    func refreshDiagnostics() {
        refreshRunning()
        do { desktopCompatibility = .available(try desktopQuotaSource.installationVersion()) }
        catch { desktopCompatibility = .unavailable(error.localizedDescription) }
        var failures: [UUID: String] = [:]
        for account in accounts where account.usesCodexDesktop {
            do { try repository.validateDesktopOwnership(for: account.id) }
            catch { failures[account.id] = error.localizedDescription }
        }
        for account in accounts where account.usesClaudeDesktop {
            do { try repository.validateClaudeOwnership(for: account.id) }
            catch { failures[account.id] = error.localizedDescription }
        }
        diagnosticStorageErrors = failures
    }

    func restartSession(_ account: Account) {
        guard !shuttingDown, !loadFailed, let current = accounts.first(where: { $0.id == account.id }),
              current.usesCodexDesktop,
              !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id) else { return }
        launchingIDs.insert(account.id)
        closingSessionIDs.insert(account.id)
        sessionTasks[account.id] = Task {
            defer {
                launchingIDs.remove(account.id)
                closingSessionIDs.remove(account.id)
                connectingSessionIDs.remove(account.id)
                sessionTasks[account.id] = nil
                refreshDiagnostics()
            }
            do {
                try await browserService.close(current)
                try await desktopQuotaSource.closeSession(current)
                try Task.checkCancellation()
                closingSessionIDs.remove(account.id)
                connectingSessionIDs.insert(account.id)
                try await desktopQuotaSource.connectSession(current)
                try Task.checkCancellation()
                quotaErrors[account.id] = nil
                lastAction = L10n.format("Restarted background session %@. Your login is kept.", current.name)
                refreshDesktopQuota(current)
            } catch is CancellationError { }
            catch { quotaErrors[account.id] = error }
        }
    }

    func defaultAction(for account: Account) -> AccountAction {
        (account.usesCodexDesktop || account.effectiveAgent.usesProviderQuota) && preferences.quotaOnlyMode ? .connectSession : account.effectiveDefaultAction
    }

    func performDefaultAction(_ account: Account) {
        if defaultAction(for: account) == .connectSession {
            if (account.effectiveAgent.usesProviderQuota ? providerSessionIDs.contains(account.id) : hasRunningSession(account)) { refreshQuota(account) }
            else { connectSession(account) }
        }
        else { open(account) }
    }

    func defaultActionTitle(for account: Account) -> String {
        if connectingSessionIDs.contains(account.id) { return L10n.text("Connecting session…") }
        if closingSessionIDs.contains(account.id) { return L10n.text("Closing session…") }
        if launchingIDs.contains(account.id) { return L10n.text("Opening…") }
        if defaultAction(for: account) == .connectSession {
            if quotaBusyIDs.contains(account.id) { return L10n.text("Reading Desktop quota…") }
            return (account.effectiveAgent.usesProviderQuota ? providerSessionIDs.contains(account.id) : hasRunningSession(account)) ? L10n.text("Refresh quota") : L10n.text("Connect account session")
        }
        return account.effectiveAgent.openTitle
    }

    /// Opt-in startup connections are sequential and never launch a Desktop window.
    func connectStartupAccounts() async {
        guard !didConnectStartupAccounts, !loadFailed, !shuttingDown else { return }
        didConnectStartupAccounts = true
        for id in accounts.filter(\.automaticallyConnects).map(\.id) {
            guard !Task.isCancelled, !shuttingDown else { return }
            guard let account = accounts.first(where: { $0.id == id }), account.automaticallyConnects else { continue }
            connectSession(account, reportFailure: false)
            await sessionTasks[id]?.value
            await quotaTasks[id]?.value
        }
    }

    func sessionStatus(for account: Account) -> SessionStatus {
        if connectingSessionIDs.contains(account.id) { return .connecting }
        if closingSessionIDs.contains(account.id) { return .closing }
        if launchingIDs.contains(account.id) { return .opening }
        if providerSessionIDs.contains(account.id) && !desktopWindowIDs.contains(account.id) { return .background }
        if (quotaErrors[account.id] as? ProviderQuotaError) == .signedOut { return .needsSignIn }
        if account.effectiveAgent.isSharedApplication {
            return agentApplications.isRunning(account.effectiveAgent) ? .applicationRunning : .disconnected
        }
        if (quotaErrors[account.id] as? CodexQuotaError) == .notSignedIn { return .needsSignIn }
        if account.effectiveLaunchMode == .browser {
            return runningIDs.contains(account.id) ? .browserOpen : .disconnected
        }
        if desktopWindowIDs.contains(account.id) { return .desktopOpen }
        if backendIDs.contains(account.id) { return .background }
        return quotaErrors[account.id] == nil ? .disconnected : .connectionFailed
    }

    var visibleAccounts: [Account] {
        var result = accounts
        switch filter {
        case .all: break
        case .favorites: result = result.filter(\.isFavorite)
        case .recent:
            result = result.filter { $0.lastOpenedAt != nil }.sorted { $0.lastOpenedAt! > $1.lastOpenedAt! }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.emailHint.localizedCaseInsensitiveContains(query) }
        }
        if let agent = preferences.agentFilter { result = result.filter { $0.effectiveAgent == agent } }
        return result
    }

    var menuAccounts: [Account] {
        accounts.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.createdAt < b.createdAt
        }
    }

    func reload() {
        do {
            snapshot = try repository.load()
            loadFailed = false
            refreshRunning()
        } catch {
            loadFailed = true
            showError(error, title: L10n.text("Could not read account list"))
        }
    }

    func addAccount() {
        guard !loadFailed else { reload(); return }
        editor = AccountEditor(account: nil, defaultBrowser: browserService.installedBrowsers.first ?? .chrome,
                               defaultColor: AccountColor.allCases[accounts.count % AccountColor.allCases.count],
                               defaultAgent: preferences.agentFilter ?? .chatgpt)
    }

    @discardableResult
    func saveAccount(_ account: Account) -> Bool {
        guard !loadFailed else { return false }
        do {
            try account.validate()
            if account.effectiveAgent.isSharedApplication,
               accounts.contains(where: { $0.id != account.id && $0.effectiveAgent == account.effectiveAgent }) {
                throw AgentLaunchError.duplicateSharedApplication
            }
            var updated = snapshot
            if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) {
                guard account.effectiveAgent == updated.accounts[index].effectiveAgent else { throw AgentLaunchError.fixedAgent }
                var edited = account
                if edited.effectiveLaunchMode != updated.accounts[index].effectiveLaunchMode
                    || edited.usesSharedLocalWorkspace != updated.accounts[index].usesSharedLocalWorkspace {
                    guard !hasRunningSession(account), !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id), pendingConnections[account.id] == nil else {
                        throw DesktopProfileError.profileRunning
                    }
                    quotaErrors[account.id] = nil
                }
                edited.providerQuotaConnection = updated.accounts[index].providerQuotaConnection
                edited.codexConnection = updated.accounts[index].codexConnection
                edited.desktopCodexConnection = updated.accounts[index].desktopCodexConnection
                edited.lastOpenedAt = updated.accounts[index].lastOpenedAt
                updated.accounts[index] = edited
            } else {
                updated.accounts.append(account)
            }
            try persist(updated)
            lastAction = L10n.format("Saved profile %@", String(describing: account.name))
            return true
        } catch { showError(error); return false }
    }

    func toggleFavorite(_ account: Account) {
        var updated = account
        updated.isFavorite.toggle()
        saveAccount(updated)
    }

    func open(_ account: Account, newWindow: Bool = false) {
        guard !launchingIDs.contains(account.id) else { return }
        launchingIDs.insert(account.id)
        Task {
            defer { launchingIDs.remove(account.id); refreshRunning() }
            do {
                if account.effectiveAgent.isSharedApplication { try await agentApplications.open(account.effectiveAgent) }
                else if account.usesClaudeDesktop { try await claudeDesktopService.open(account) }
                else if account.usesCodexDesktop { try await desktopService.open(account) }
                else { try await browserService.open(account, forceNewWindow: newWindow) }
                // Preserve label edits made while the application was launching.
                var updated = snapshot
                if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) {
                    updated.accounts[index].lastOpenedAt = Date()
                    updated.lastOpenedID = account.id
                    try persist(updated)
                }
                lastAction = L10n.format("Opened %@", String(describing: account.name))
                if account.usesCodexDesktop && !quotaBusyIDs.contains(account.id) { refreshDesktopQuota(account) }
            } catch { showError(error, title: L10n.text("Could not open account")) }
        }
    }

    func canConnectSession(_ account: Account) -> Bool {
        if account.effectiveAgent.usesProviderQuota {
            return !shuttingDown && !loadFailed && !installingProviderAgents.contains(account.effectiveAgent) && !launchingIDs.contains(account.id) && !quotaBusyIDs.contains(account.id) && !providerSessionIDs.contains(account.id) && accounts.contains(where: { $0.id == account.id })
        }
        return !shuttingDown && !loadFailed && account.usesCodexDesktop
            && accounts.contains(where: { $0.id == account.id })
            && !launchingIDs.contains(account.id) && !quotaBusyIDs.contains(account.id)
            && !hasRunningSession(account) && !desktopQuotaSource.hasDesktopWindow(account)
    }

    func connectSession(_ account: Account, reportFailure: Bool = true) {
        if account.effectiveAgent.usesProviderQuota { refreshProviderQuota(account, connect: true); return }
        guard !shuttingDown, !loadFailed, let current = accounts.first(where: { $0.id == account.id }),
              canConnectSession(current) else { return }
        launchingIDs.insert(account.id)
        connectingSessionIDs.insert(account.id)
        sessionTasks[account.id] = Task {
            defer {
                launchingIDs.remove(account.id)
                connectingSessionIDs.remove(account.id)
                sessionTasks[account.id] = nil
                refreshRunning()
            }
            do {
                try await desktopQuotaSource.connectSession(current)
                try Task.checkCancellation()
                lastAction = L10n.format("Connected session %@ without opening Desktop.", current.name)
                refreshDesktopQuota(current)
            } catch is CancellationError { }
            catch {
                quotaErrors[account.id] = error
                if reportFailure { showError(error, title: L10n.text("Could not connect account session")) }
            }
        }
    }

    func closeSession(_ account: Account) {
        if account.effectiveAgent.usesProviderQuota {
            providerSessionIDs.remove(account.id);quotaTasks[account.id]?.cancel();claudeWeb.stop(account.id);Task { await providerQuota.stop(account.id) }
            if account.effectiveAgent.isSharedApplication { refreshRunning(); return }
        }
        guard !account.effectiveAgent.isSharedApplication else { return }
        guard !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id) else { return }
        launchingIDs.insert(account.id)
        closingSessionIDs.insert(account.id)
        Task {
            defer { launchingIDs.remove(account.id); closingSessionIDs.remove(account.id); refreshRunning() }
            do {
                if account.effectiveAgent == .claude { try await claudeDesktopService.close(account) }
                try await browserService.close(account)
                if account.effectiveAgent.supportsCodexQuota { try await desktopQuotaSource.closeSession(account) }
                quotaErrors[account.id] = nil
                lastAction = L10n.format("Closed session %@. Your login is kept.", String(describing: account.name))
            } catch { showError(error) }
        }
    }

    func delete(_ account: Account) {
        guard !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id), pendingConnections[account.id] == nil else { return }
        do {
            guard !hasRunningSession(account) else { throw DesktopProfileError.profileRunning }
            snapshot = try repository.remove(account.id, from: snapshot)
            if account.effectiveAgent == .claude { webCleanupTasks[account.id] = Task { await claudeWeb.remove(account);webCleanupTasks[account.id] = nil } }
            lastAction = L10n.format("Deleted local profile %@", String(describing: account.name))
        } catch {
            reload()
            showError(error, title: L10n.text("Could not finish deleting profile"))
        }
        refreshRunning()
    }

    func refreshRunning() {
        let ids = Set(accounts.filter { hasRunningSession($0) }.map(\.id))
        if ids != runningIDs { runningIDs = ids }
        let windows = Set(accounts.filter { ($0.usesCodexDesktop && desktopQuotaSource.hasDesktopWindow($0)) || ($0.usesClaudeDesktop && claudeDesktopService.hasWindow($0)) }.map(\.id))
        if windows != desktopWindowIDs { desktopWindowIDs = windows }
        let backends = Set(accounts.filter { $0.usesCodexDesktop && desktopQuotaSource.hasBackend($0.id) }.map(\.id))
        if backends != backendIDs { backendIDs = backends }
    }

    func hasRunningSession(_ account: Account) -> Bool {
        if providerSessionIDs.contains(account.id) { return true }
        if account.effectiveAgent.isSharedApplication { return false }
        return (account.effectiveAgent == .claude && claudeDesktopService.runningApplication(for: account) != nil)
            || browserService.runningApplication(for: account) != nil
            || (account.effectiveAgent.supportsCodexQuota && desktopService.runningApplication(for: account) != nil)
            || (account.usesCodexDesktop && desktopQuotaSource.hasBackend(account.id))
    }

    /// Opening Desktop normally precedes OAuth completion. Retry local identity
    /// reads until that existing session can return quota; never start another login.
    func refreshDesktopQuotaIfNeeded(now: Date = Date()) {
        let active = accounts.filter { $0.usesCodexDesktop && desktopQuotaSource.hasBackend($0.id) }
        let activeIDs = Set(active.map(\.id))
        desktopQuotaRetryAt = desktopQuotaRetryAt.filter { activeIDs.contains($0.key) }
        for account in active where !launchingIDs.contains(account.id) && !quotaBusyIDs.contains(account.id) {
            guard account.desktopCodexConnection?.quota == nil || quotaErrors[account.id] != nil,
                  now >= (desktopQuotaRetryAt[account.id] ?? .distantPast) else { continue }
            refreshQuota(account)
        }
    }

    func quotaErrorDescription(for account: Account) -> String? {
        guard let error = quotaErrors[account.id] else { return nil }
        guard account.effectiveLaunchMode == .desktop, let codexError = error as? CodexQuotaError else {
            return error.localizedDescription
        }
        switch codexError {
        case .notSignedIn:
            return L10n.text("This session is not signed in. Use Open ChatGPT once to sign in, then connect the session to read quota without opening Desktop.")
        case .identityChanged:
            return L10n.text("The Desktop account changed. Quota will refresh automatically.")
        case .rpc:
            return L10n.text("Could not read quota from this Desktop session. AI Switcher will retry automatically.")
        default:
            return error.localizedDescription
        }
    }

    func connectQuota(_ account: Account) {
        if account.effectiveAgent.usesProviderQuota { connectSession(account); return }
        guard account.effectiveAgent.supportsCodexQuota else { return }
        if account.effectiveLaunchMode == .desktop { connectSession(account); return }
        guard connectingID == nil, !quotaBusyIDs.contains(account.id), quotaCleanupTasks[account.id] == nil,
              account.codexConnection == nil else { return }
        connectingID = account.id
        quotaBusyIDs.insert(account.id)
        quotaErrors[account.id] = nil
        quotaTasks[account.id] = Task {
            defer { connectingID = nil; finishQuotaOperation(account.id) }
            do {
                let connection = try await quotaService.connect(account.id) { [self] url in
                    try await browserService.open(account, forceNewWindow: true, url: url)
                }
                try Task.checkCancellation()
                pendingConnections[account.id] = connection
            } catch is CancellationError { }
            catch { quotaErrors[account.id] = error }
        }
    }

    @discardableResult
    func confirmQuotaConnection(_ id: UUID) -> Bool {
        guard let connection = pendingConnections[id] else { return false }
        do {
            try storeConnection(connection, for: id)
            pendingConnections[id] = nil
            quotaErrors[id] = nil
            lastAction = L10n.text("Codex quota connected")
            // OAuth's success page can be the only or frontmost browser window.
            // Open ChatGPT once after setup so future switches target that app.
            if let account = accounts.first(where: { $0.id == id }) { open(account, newWindow: true) }
            return true
        } catch { quotaErrors[id] = error; return false }
    }

    func cancelQuotaConnection(_ id: UUID) {
        guard (connectingID == id || pendingConnections[id] != nil), quotaCleanupTasks[id] == nil else { return }
        let operation = quotaTasks[id]
        operation?.cancel()
        pendingConnections[id] = nil
        quotaBusyIDs.insert(id)
        quotaCleanupTasks[id] = Task {
            await operation?.value
            do { try await quotaService.discardUnconfirmed(id) }
            catch { quotaErrors[id] = error }
            quotaBusyIDs.remove(id)
            quotaCleanupTasks[id] = nil
        }
    }

    func disconnectQuota(_ id: UUID) {
        guard !quotaBusyIDs.contains(id), let account = accounts.first(where: { $0.id == id }),
              account.effectiveAgent.supportsCodexQuota, account.effectiveLaunchMode == .browser else { return }
        quotaBusyIDs.insert(id)
        quotaTasks[id] = Task {
            defer { finishQuotaOperation(id) }
            do {
                try await quotaService.disconnect(id)
                try storeConnection(nil, for: id)
                quotaErrors[id] = nil
                lastAction = L10n.text("Disconnected Codex for this profile")
            } catch { quotaErrors[id] = error }
        }
    }

    func refreshQuota(_ account: Account) {
        if account.effectiveAgent.usesProviderQuota { refreshProviderQuota(account); return }
        guard account.effectiveAgent.supportsCodexQuota else { return }
        guard !quotaBusyIDs.contains(account.id) else { return }
        if account.effectiveLaunchMode == .desktop {
            if !desktopQuotaSource.hasBackend(account.id) { connectSession(account) }
            else if !launchingIDs.contains(account.id) { refreshDesktopQuota(account) }
            return
        }
        guard let connection = account.codexConnection else { return }
        quotaBusyIDs.insert(account.id)
        quotaTasks[account.id] = Task {
            defer { finishQuotaOperation(account.id) }
            do {
                let refreshed = try await quotaService.refresh(account.id, connection: connection)
                try storeConnection(refreshed, for: account.id)
                quotaErrors[account.id] = nil
                await notifyQuota(account.id)
            } catch {
                quotaErrors[account.id] = error
            }
        }
    }

    func hasProviderCLI(_ account: Account) -> Bool {
        // Signed-out sessions still have an installed CLI. Keep setup available for incompatible selections.
        if let error = quotaErrors[account.id] as? ProviderQuotaError,
           error == .cliOutdated || error == .invalidExecutable { return false }
        return (try? providerQuota.executable(account.effectiveAgent, override: preferences.providerExecutables[account.effectiveAgent.rawValue])) != nil
    }

    func installProviderCLI(_ account: Account) {
        let agent = account.effectiveAgent
        guard agent.usesProviderQuota, !shuttingDown, !loadFailed, !installingProviderAgents.contains(agent),
              !quotaBusyIDs.contains(account.id), accounts.contains(where: { $0.id == account.id }) else { return }
        installingProviderAgents.insert(agent);providerInstallationErrors[agent] = nil
        providerInstallationTasks[agent] = Task {
            defer { installingProviderAgents.remove(agent);providerInstallationTasks[agent] = nil }
            do {
                let job = try ProviderCLIInstallation(agent: agent, root: repository.root)
                try job.prepare()
                defer { job.cleanupIfFinished() }
                try Task.checkCancellation()
                let config = NSWorkspace.OpenConfiguration();config.activates = true
                _ = try await NSWorkspace.shared.open([job.launcher], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: config)
                try await job.wait()
                guard let current = accounts.first(where: { $0.id == account.id }) else { return }
                let cli = try await providerQuota.verifiedExecutable(current, override: nil)
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                var next = preferences;next.providerExecutables[agent.rawValue] = cli.path;preferencesStore.save(next);preferences = next
                for profile in accounts where profile.effectiveAgent == agent { quotaErrors[profile.id] = nil }
                installingProviderAgents.remove(agent)
                if let current = accounts.first(where: { $0.id == account.id }) { connectSession(current) }
            } catch is CancellationError {} catch {
                providerInstallationErrors[agent] = error.localizedDescription
            }
        }
    }

    func setProviderExecutable(_ agent: AIAgent) {
        let picker = NSOpenPanel();picker.canChooseDirectories = false;picker.allowsMultipleSelection = false
        picker.treatsFilePackagesAsDirectories = true
        picker.message = L10n.text("Choose the CLI executable, not the Desktop application.")
        if picker.runModal() == .OK, let url = picker.url {
            guard ProviderQuotaService.isCLIExecutable(url, agent: agent) else { showError(ProviderQuotaError.invalidExecutable);return }
            var next = preferences;next.providerExecutables[agent.rawValue] = url.path;preferencesStore.save(next);preferences = next;providerInstallationErrors[agent] = nil
            for account in accounts where account.effectiveAgent == agent {
                if let error = quotaErrors[account.id] as? ProviderQuotaError,
                   error == .cliMissing || error == .cliOutdated || error == .invalidExecutable { quotaErrors[account.id] = nil }
            }
        }
    }
    func cancelProviderConnection(_ account: Account) { quotaTasks[account.id]?.cancel();claudeWeb.stop(account.id);Task { await providerQuota.stop(account.id) } }
    private func refreshProviderQuota(_ account: Account, connect: Bool = false) {
        guard !shuttingDown, !loadFailed, !installingProviderAgents.contains(account.effectiveAgent), !quotaBusyIDs.contains(account.id), accounts.contains(where: { $0.id == account.id }) else { return }
        if connect && !canConnectSession(account) { return }
        quotaBusyIDs.insert(account.id);if connect { connectingSessionIDs.insert(account.id) };lastQuotaChecks[account.id] = Date()
        quotaTasks[account.id] = Task {
            defer { providerSignInIDs.remove(account.id);connectingSessionIDs.remove(account.id);finishQuotaOperation(account.id);refreshRunning() }
            do {
                let storeIdentity: (CodexIdentity, String?) throws -> Void = { [self] identity, kind in
                    try Task.checkCancellation()
                    guard let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }) else { throw ProfileError.invalidSelection }
                    var updated = snapshot
                    let old = updated.accounts[index].providerQuotaConnection
                    let keepQuota = old?.identity.matches(identity) == true && old?.identity.planType == identity.planType && identity.planType != "free"
                    updated.accounts[index].providerQuotaConnection = CodexConnection(identity: identity, quota: keepQuota ? old?.quota : nil, identityFetchedAt: Date(), providerSessionKind: kind)
                    try persist(updated);providerSessionIDs.insert(account.id)
                }
                let usesWeb = account.effectiveAgent == .claude && account.providerQuotaConnection?.providerSessionKind == "claudeWeb"
                let read = { [self] in
                    if usesWeb { return try await claudeWeb.read(account, onIdentity: { try storeIdentity($0, "claudeWeb") }) }
                    return try await providerQuota.read(account, override: preferences.providerExecutables[account.effectiveAgent.rawValue], onIdentity: { try storeIdentity($0, nil) })
                }
                let value: CodexConnection
                if connect && account.effectiveAgent == .claude {
                    do { value = try await read() }
                    catch let error as ProviderQuotaError where [.signedOut, .cliMissing, .cliOutdated].contains(error) {
                        value = try await claudeWeb.read(account, interactive: true, onSignIn: { [self] in
                            quotaErrors[account.id] = nil;providerSignInIDs.insert(account.id)
                        }, onIdentity: { try storeIdentity($0, "claudeWeb") })
                    }
                } else if connect {
                    value = try await ProviderSessionConnector.connect(read: read, signIn: { [self] in
                        providerSessionIDs.remove(account.id);quotaErrors[account.id] = nil;providerSignInIDs.insert(account.id)
                        try await providerQuota.signIn(account, override: preferences.providerExecutables[account.effectiveAgent.rawValue])
                    })
                } else { value = try await read() }
                try Task.checkCancellation()
                guard let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }) else { return }
                var updated = snapshot;updated.accounts[index].providerQuotaConnection = value;try persist(updated)
                providerSessionIDs.insert(account.id);quotaErrors[account.id] = nil;await notifyQuota(account.id)
            } catch is CancellationError {} catch {
                quotaErrors[account.id] = error
                if (error as? ProviderQuotaError) == .identityChanged || (error as? ProviderQuotaError) == .signedOut { providerSessionIDs.remove(account.id) }
            }
        }
    }

    private func refreshDesktopQuota(_ account: Account) {
        quotaBusyIDs.insert(account.id)
        quotaTasks[account.id] = Task {
            defer { finishQuotaOperation(account.id) }
            do {
                var client = try desktopQuotaSource.quotaClient(account.id)
                desktopQuotaClients[account.id] = client
                do {
                    try await client.start()
                    let identity: CodexIdentity
                    do {
                        identity = try await client.readIdentity()
                    } catch CodexQuotaError.notSignedIn {
                        await client.stop()
                        try Task.checkCancellation()
                        guard let persisted = try desktopQuotaSource.persistedSessionQuotaClient(account.id) else {
                            throw CodexQuotaError.notSignedIn
                        }
                        client = persisted
                        desktopQuotaClients[account.id] = client
                        try await client.start()
                        identity = try await client.readIdentity()
                    }
                    let limits = try await client.readLimits()
                    let after = try await client.readIdentity()
                    guard identity.matches(after) else { throw CodexQuotaError.identityChanged }
                    try Task.checkCancellation()
                    let current = CodexIdentity(email: after.email, planType: after.planType, accountId: limits.accountId)
                    try storeConnection(CodexConnection(identity: current, quota: CodexQuotaSnapshot(limits: limits)),
                                        for: account.id, mode: .desktop)
                    quotaErrors[account.id] = nil
                    desktopQuotaRetryAt[account.id] = nil
                    await client.stop()
                    desktopQuotaClients[account.id] = nil
                    await notifyQuota(account.id)
                } catch {
                    await client.stop()
                    desktopQuotaClients[account.id] = nil
                    throw error
                }
            } catch is CancellationError { }
            catch {
                if let error = error as? CodexQuotaError, error == .notSignedIn || error == .identityChanged {
                    try? storeConnection(nil, for: account.id, mode: .desktop)
                }
                quotaErrors[account.id] = error
                let waitingForSession = (error as? CodexQuotaError).map { $0 == .notSignedIn || $0 == .identityChanged } ?? false
                desktopQuotaRetryAt[account.id] = Date().addingTimeInterval(waitingForSession ? 3 : 30)
            }
        }
    }

    func refreshAllQuotas() {
        guard quotaSweepTask == nil else { return }
        quotaSweepTask = Task {
            defer { quotaSweepTask = nil }
            for account in accounts where providerSessionIDs.contains(account.id) { refreshProviderQuota(account) }
            for id in accounts.filter({ $0.effectiveAgent.supportsCodexQuota && ($0.usesCodexDesktop ? desktopQuotaSource.hasBackend($0.id) : $0.codexConnection != nil) }).map(\.id) {
                if Task.isCancelled { return }
                guard let account = accounts.first(where: { $0.id == id }) else { continue }
                refreshQuota(account)
                await quotaTasks[id]?.value
            }
        }
    }

    func shutdownQuota() async {
        shuttingDown = true
        startupTask?.cancel()
        refreshTimer?.cancel()
        quotaTimer?.cancel()
        quotaSweepTask?.cancel()
        let sessions = Array(sessionTasks.values)
        for task in sessions { task.cancel() }
        for task in sessions { await task.value }
        await startupTask?.value
        if let id = connectingID { cancelQuotaConnection(id) }
        for id in Array(pendingConnections.keys) { cancelQuotaConnection(id) }
        let installationTasks = Array(providerInstallationTasks.values)
        for task in installationTasks { task.cancel() }
        for task in installationTasks { await task.value }
        let pendingQuotaTasks = Array(quotaTasks.values)
        for task in pendingQuotaTasks { task.cancel() }
        claudeWeb.stopAll()
        for task in pendingQuotaTasks { await task.value }
        for client in desktopQuotaClients.values { await client.stop() }
        await quotaService.stopAll()
        for task in quotaCleanupTasks.values { await task.value }
        for task in Array(webCleanupTasks.values) { await task.value }
    }

    private func finishQuotaOperation(_ id: UUID) {
        lastQuotaChecks[id] = Date()
        if quotaCleanupTasks[id] == nil { quotaBusyIDs.remove(id) }
        quotaTasks[id] = nil
        refreshRunning()
    }

    private func storeConnection(_ connection: CodexConnection?, for id: UUID, mode: LaunchMode = .browser) throws {
        var updated = snapshot
        guard let index = updated.accounts.firstIndex(where: { $0.id == id }) else { throw ProfileError.invalidSelection }
        if mode == .desktop { updated.accounts[index].desktopCodexConnection = connection }
        else { updated.accounts[index].codexConnection = connection }
        try persist(updated)
    }

    func revealData() {
        do {
            try FileManager.default.createDirectory(at: repository.root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(repository.root)
        } catch { showError(error) }
    }

    private func persist(_ updated: AccountSnapshot) throws {
        guard !loadFailed else { return }
        try repository.save(updated)
        snapshot = updated
    }

    private func showError(_ error: Error, title: String = L10n.text("Something went wrong")) {
        notice = AppNotice(title: title, message: error.localizedDescription)
    }
}

struct AccountEditor: Identifiable {
    let id = UUID()
    let account: Account?
    let defaultBrowser: BrowserKind
    let defaultColor: AccountColor
    let defaultAgent: AIAgent

    init(account: Account?, defaultBrowser: BrowserKind = .chrome, defaultColor: AccountColor = .mint, defaultAgent: AIAgent = .chatgpt) {
        self.account = account
        self.defaultBrowser = defaultBrowser
        self.defaultColor = defaultColor
        self.defaultAgent = defaultAgent
    }
}
