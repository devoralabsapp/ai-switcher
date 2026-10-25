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
    @Published var showGuide = false
    @Published var showPreferences = false
    @Published private(set) var preferences = AppPreferencesStore().load()
    @Published private(set) var launchingIDs: Set<UUID> = []
    @Published private(set) var connectingSessionIDs: Set<UUID> = []
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
    let desktopService: DesktopService
    let quotaService: CodexQuotaService
    private let desktopQuotaSource: any DesktopQuotaSource
    private var refreshTimer: AnyCancellable?
    private var quotaTimer: AnyCancellable?
    private var quotaTasks: [UUID: Task<Void, Never>] = [:]
    private var quotaSweepTask: Task<Void, Never>?
    private var quotaCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var desktopQuotaClients: [UUID: CodexRPCClient] = [:]
    private var desktopQuotaRetryAt: [UUID: Date] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]

    init(root: URL, preferences: AppPreferences? = nil, monitoring: Bool = true,
         desktopQuotaSource: (any DesktopQuotaSource)? = nil) {
        self.preferences = preferences ?? AppPreferencesStore().load()
        repository = ProfileRepository(root: root)
        browserService = BrowserService(repository: repository)
        desktopService = DesktopService(repository: repository)
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
        Task { [weak self] in self?.refreshAllQuotas() }
    }

    var accounts: [Account] { snapshot.accounts }
    var lastOpened: Account? { accounts.first { $0.id == snapshot.lastOpenedID } }

    func setLanguage(_ language: AppLanguage) {
        var updated = preferences
        updated.language = language
        AppPreferencesStore().save(updated)
        lastAction = nil
        preferences = updated
    }

    func setTheme(_ theme: AppTheme) {
        var updated = preferences
        updated.theme = theme
        AppPreferencesStore().save(updated)
        preferences = updated
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
                               defaultColor: AccountColor.allCases[accounts.count % AccountColor.allCases.count])
    }

    @discardableResult
    func saveAccount(_ account: Account) -> Bool {
        guard !loadFailed else { return false }
        do {
            try account.validate()
            var updated = snapshot
            if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) {
                var edited = account
                if edited.effectiveLaunchMode != updated.accounts[index].effectiveLaunchMode
                    || edited.usesSharedLocalWorkspace != updated.accounts[index].usesSharedLocalWorkspace {
                    guard !hasRunningSession(account), !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id), pendingConnections[account.id] == nil else {
                        throw DesktopProfileError.profileRunning
                    }
                    quotaErrors[account.id] = nil
                }
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
                if account.effectiveLaunchMode == .desktop { try await desktopService.open(account) }
                else { try await browserService.open(account, forceNewWindow: newWindow) }
                // Preserve label edits made while the application was launching.
                var updated = snapshot
                if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) {
                    updated.accounts[index].lastOpenedAt = Date()
                    updated.lastOpenedID = account.id
                    try persist(updated)
                }
                lastAction = L10n.format("Opened %@", String(describing: account.name))
                if account.effectiveLaunchMode == .desktop && !quotaBusyIDs.contains(account.id) { refreshDesktopQuota(account) }
            } catch { showError(error, title: L10n.text("Could not open account")) }
        }
    }

    func connectSession(_ account: Account) {
        guard !loadFailed, let current = accounts.first(where: { $0.id == account.id }),
              current.effectiveLaunchMode == .desktop,
              !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id) else { return }
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
                showError(error, title: L10n.text("Could not connect account session"))
            }
        }
    }

    func closeSession(_ account: Account) {
        guard !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id) else { return }
        launchingIDs.insert(account.id)
        Task {
            defer { launchingIDs.remove(account.id); refreshRunning() }
            do {
                try await browserService.close(account)
                try await desktopService.close(account)
                lastAction = L10n.format("Closed session %@. Your login is kept.", String(describing: account.name))
            } catch { showError(error) }
        }
    }

    func delete(_ account: Account) {
        guard !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id), pendingConnections[account.id] == nil else { return }
        do {
            guard !hasRunningSession(account) else { throw DesktopProfileError.profileRunning }
            snapshot = try repository.remove(account.id, from: snapshot)
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
    }

    func hasRunningSession(_ account: Account) -> Bool {
        browserService.runningApplication(for: account) != nil || desktopService.runningApplication(for: account) != nil
            || desktopQuotaSource.hasBackend(account.id)
    }

    /// Opening Desktop normally precedes OAuth completion. Retry local identity
    /// reads until that existing session can return quota; never start another login.
    func refreshDesktopQuotaIfNeeded(now: Date = Date()) {
        let active = accounts.filter { $0.effectiveLaunchMode == .desktop && desktopQuotaSource.hasBackend($0.id) }
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
        guard !quotaBusyIDs.contains(id), accounts.first(where: { $0.id == id })?.effectiveLaunchMode == .browser else { return }
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
            } catch {
                quotaErrors[account.id] = error
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
            for id in accounts.filter({ $0.effectiveLaunchMode == .desktop ? desktopQuotaSource.hasBackend($0.id) : $0.codexConnection != nil }).map(\.id) {
                if Task.isCancelled { return }
                guard let account = accounts.first(where: { $0.id == id }) else { continue }
                refreshQuota(account)
                await quotaTasks[id]?.value
            }
        }
    }

    func shutdownQuota() async {
        refreshTimer?.cancel()
        quotaTimer?.cancel()
        quotaSweepTask?.cancel()
        let sessions = Array(sessionTasks.values)
        for task in sessions { task.cancel() }
        for task in sessions { await task.value }
        if let id = connectingID { cancelQuotaConnection(id) }
        for id in Array(pendingConnections.keys) { cancelQuotaConnection(id) }
        for task in quotaTasks.values { task.cancel() }
        for client in desktopQuotaClients.values { await client.stop() }
        await quotaService.stopAll()
        for task in quotaCleanupTasks.values { await task.value }
    }

    private func finishQuotaOperation(_ id: UUID) {
        if quotaCleanupTasks[id] == nil { quotaBusyIDs.remove(id) }
        quotaTasks[id] = nil
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

    init(account: Account?, defaultBrowser: BrowserKind = .chrome, defaultColor: AccountColor = .mint) {
        self.account = account
        self.defaultBrowser = defaultBrowser
        self.defaultColor = defaultColor
    }
}
