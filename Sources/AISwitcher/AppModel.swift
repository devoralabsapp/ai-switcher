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

    let repository: ProfileRepository
    let browserService: BrowserService
    private var refreshTimer: AnyCancellable?

    init(root: URL) {
        repository = ProfileRepository(root: root)
        browserService = BrowserService(repository: repository)
        reload()
        refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshRunning()
        }
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
                updated.accounts[index] = account
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
                try await browserService.open(account, forceNewWindow: newWindow)
                // Preserve label edits made while the browser was launching.
                var updated = snapshot
                if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) {
                    updated.accounts[index].lastOpenedAt = Date()
                    updated.lastOpenedID = account.id
                    try persist(updated)
                }
                lastAction = "Đã mở \(account.name)"
            } catch { showError(error, title: "Chưa mở được tài khoản") }
        }
    }

    func closeSession(_ account: Account) {
        guard !launchingIDs.contains(account.id) else { return }
        launchingIDs.insert(account.id)
        Task {
            defer { launchingIDs.remove(account.id); refreshRunning() }
            do {
                try await browserService.close(account)
                lastAction = "Đã đóng phiên \(account.name). Đăng nhập vẫn được giữ."
            } catch { showError(error) }
        }
    }

    func delete(_ account: Account) {
        guard !launchingIDs.contains(account.id) else { return }
        do {
            guard browserService.runningApplication(for: account) == nil else { throw ProfileError.profileRunning }
            snapshot = try repository.remove(account.id, from: snapshot)
            lastAction = "Đã xóa hồ sơ \(account.name) trên máy này"
        } catch {
            reload()
            showError(error, title: "Chưa xóa xong hồ sơ")
        }
        refreshRunning()
    }

    func refreshRunning() {
        let ids = Set(accounts.filter { browserService.runningApplication(for: $0) != nil }.map(\.id))
        if ids != runningIDs { runningIDs = ids }
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
