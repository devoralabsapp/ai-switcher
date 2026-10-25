import AppKit
import AISwitcherCore
import Combine

enum AccountFilter: String, CaseIterable {
    case all = "Tất cả tài khoản"
    case favorites = "Yêu thích"
    case recent = "Gần đây"

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
    @Published private(set) var launchingIDs: Set<UUID> = []
    @Published private(set) var runningIDs: Set<UUID> = []
    @Published private(set) var loadFailed = false
    @Published private(set) var lastAction: String?
    @Published var quotaAccountID: UUID?
    @Published private(set) var quotaBusyIDs: Set<UUID> = []
    @Published private(set) var quotaErrors: [UUID: String] = [:]
    @Published private(set) var pendingConnections: [UUID: CodexConnection] = [:]
    @Published private(set) var connectingID: UUID?

    let repository: ProfileRepository
    let browserService: BrowserService
    let desktopService: DesktopService
    let quotaService: CodexQuotaService
    private var refreshTimer: AnyCancellable?
    private var quotaTimer: AnyCancellable?
    private var quotaTasks: [UUID: Task<Void, Never>] = [:]
    private var quotaSweepTask: Task<Void, Never>?
    private var quotaCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var desktopQuotaClients: [UUID: CodexRPCClient] = [:]

    init(root: URL) {
        repository = ProfileRepository(root: root)
        browserService = BrowserService(repository: repository)
        desktopService = DesktopService(repository: repository)
        quotaService = CodexQuotaService(repository: repository)
        reload()
        refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshRunning()
        }
        quotaTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshAllQuotas()
        }
        Task { [weak self] in self?.refreshAllQuotas() }
    }

    var accounts: [Account] { snapshot.accounts }
    var lastOpened: Account? { accounts.first { $0.id == snapshot.lastOpenedID } }

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
            showError(error, title: "Chưa đọc được danh sách tài khoản")
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
                if edited.effectiveLaunchMode != updated.accounts[index].effectiveLaunchMode {
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
            lastAction = "Đã lưu hồ sơ \(account.name)"
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
                lastAction = "Đã mở \(account.name)"
                if account.effectiveLaunchMode == .desktop { refreshQuota(account) }
            } catch { showError(error, title: "Chưa mở được tài khoản") }
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
                lastAction = "Đã đóng phiên \(account.name). Đăng nhập vẫn được giữ."
            } catch { showError(error) }
        }
    }

    func delete(_ account: Account) {
        guard !launchingIDs.contains(account.id), !quotaBusyIDs.contains(account.id), pendingConnections[account.id] == nil else { return }
        do {
            guard !hasRunningSession(account) else { throw DesktopProfileError.profileRunning }
            snapshot = try repository.remove(account.id, from: snapshot)
            lastAction = "Đã xóa hồ sơ \(account.name) trên máy này"
        } catch {
            reload()
            showError(error, title: "Chưa xóa xong hồ sơ")
        }
        refreshRunning()
    }

    func refreshRunning() {
        let ids = Set(accounts.filter { hasRunningSession($0) }.map(\.id))
        if ids != runningIDs { runningIDs = ids }
    }

    func hasRunningSession(_ account: Account) -> Bool {
        browserService.runningApplication(for: account) != nil || desktopService.runningApplication(for: account) != nil
            || desktopService.hasBackend(account.id)
    }

    func connectQuota(_ account: Account) {
        if account.effectiveLaunchMode == .desktop { open(account); return }
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
            catch { quotaErrors[account.id] = error.localizedDescription }
        }
    }

    @discardableResult
    func confirmQuotaConnection(_ id: UUID) -> Bool {
        guard let connection = pendingConnections[id] else { return false }
        do {
            try storeConnection(connection, for: id)
            pendingConnections[id] = nil
            quotaErrors[id] = nil
            lastAction = "Đã kết nối quota Codex"
            // OAuth's success page can be the only or frontmost browser window.
            // Open ChatGPT once after setup so future switches target that app.
            if let account = accounts.first(where: { $0.id == id }) { open(account, newWindow: true) }
            return true
        } catch { quotaErrors[id] = error.localizedDescription; return false }
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
            catch { quotaErrors[id] = error.localizedDescription }
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
                lastAction = "Đã ngắt kết nối Codex cho hồ sơ này"
            } catch { quotaErrors[id] = error.localizedDescription }
        }
    }

    func refreshQuota(_ account: Account) {
        guard !quotaBusyIDs.contains(account.id) else { return }
        if account.effectiveLaunchMode == .desktop { refreshDesktopQuota(account); return }
        guard let connection = account.codexConnection else { return }
        quotaBusyIDs.insert(account.id)
        quotaTasks[account.id] = Task {
            defer { finishQuotaOperation(account.id) }
            do {
                let refreshed = try await quotaService.refresh(account.id, connection: connection)
                try storeConnection(refreshed, for: account.id)
                quotaErrors[account.id] = nil
            } catch {
                quotaErrors[account.id] = error.localizedDescription
            }
        }
    }

    private func refreshDesktopQuota(_ account: Account) {
        quotaBusyIDs.insert(account.id)
        quotaTasks[account.id] = Task {
            defer { finishQuotaOperation(account.id) }
            do {
                let client = try desktopService.quotaClient(account.id)
                desktopQuotaClients[account.id] = client
                do {
                    try await client.start()
                    let identity = try await client.readIdentity()
                    let limits = try await client.readLimits()
                    let after = try await client.readIdentity()
                    guard identity.matches(after) else { throw CodexQuotaError.identityChanged }
                    try Task.checkCancellation()
                    let current = CodexIdentity(email: after.email, planType: after.planType, accountId: limits.accountId)
                    try storeConnection(CodexConnection(identity: current, quota: CodexQuotaSnapshot(limits: limits)),
                                        for: account.id, mode: .desktop)
                    quotaErrors[account.id] = nil
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
                quotaErrors[account.id] = error.localizedDescription
            }
        }
    }

    func refreshAllQuotas() {
        guard quotaSweepTask == nil else { return }
        quotaSweepTask = Task {
            defer { quotaSweepTask = nil }
            for id in accounts.filter({ $0.effectiveLaunchMode == .desktop ? desktopService.hasBackend($0.id) : $0.codexConnection != nil }).map(\.id) {
                if Task.isCancelled { return }
                guard let account = accounts.first(where: { $0.id == id }) else { continue }
                refreshQuota(account)
                await quotaTasks[id]?.value
            }
        }
    }

    func shutdownQuota() async {
        quotaTimer?.cancel()
        quotaSweepTask?.cancel()
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

    private func showError(_ error: Error, title: String = "Có lỗi xảy ra") {
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
