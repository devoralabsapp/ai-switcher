import Foundation
import Security
import LocalAuthentication
import AISwitcherCore

@MainActor
protocol ClaudeDesktopQuotaReading {
    func hasSession(_ account: Account) -> Bool
    func read(_ account: Account, interactive: Bool, onIdentity: ((CodexIdentity) throws -> Void)?) async throws -> CodexConnection
}

@MainActor
final class ClaudeDesktopQuotaService: ClaudeDesktopQuotaReading {
    private let repository: ProfileRepository
    private let password: @Sendable (Bool) throws -> Data
    private let fetch: (URLRequest) async throws -> (Data, Int)
    init(repository: ProfileRepository, password: (@Sendable (Bool) throws -> Data)? = nil,
         fetch: ((URLRequest) async throws -> (Data, Int))? = nil) {
        self.repository = repository
        let access = ClaudeSafeStorageAccess()
        self.password = password ?? { interactive in try access.read(interactive: interactive) }
        self.fetch = fetch ?? Self.request
    }
    func hasSession(_ account: Account) -> Bool {
        account.usesClaudeDesktop && (try? repository.validateClaudeOwnership(for: account.id)) != nil
            && ClaudeDesktopCookies.hasSession(userData: repository.claudeUserDataURL(for: account.id))
    }
    func read(_ account: Account, interactive: Bool = false,
              onIdentity: ((CodexIdentity) throws -> Void)? = nil) async throws -> CodexConnection {
        guard account.usesClaudeDesktop else { throw ProviderQuotaError.signedOut }
        try repository.validateClaudeOwnership(for: account.id)
        let home = repository.claudeUserDataURL(for: account.id)
        let password = self.password
        let cookie = try await Task.detached(priority: .userInitiated) {
            try ClaudeDesktopCookies.read(userData: home, password: { try password(interactive) })
        }.value
        try Task.checkCancellation()
        func read(_ path: String) async throws -> Data {
            try Task.checkCancellation()
            let (data, status) = try await fetch(cookie.request(path: path))
            guard data.count <= 262_144 else { throw ProviderQuotaError.invalidResponse }
            if status == 401 { throw ProviderQuotaError.signedOut }
            guard status == 200 else { throw ClaudeDesktopQuotaError.unavailable }
            return data
        }
        let accountData = try await read("/api/account")
        let organizations = try await read("/api/organizations")
        let metadata = try ClaudeWebAccount.parseAPI(account: accountData, organizations: organizations,
            selectedOrganizationID: cookie.organizationID, emailHint: account.emailHint)
        try onIdentity?(metadata.identity)
        var quota: CodexQuotaSnapshot?
        // Free is deliberately included. Absence of a percentage never means 100%.
        if let organization = metadata.organizationID {
            do { quota = try ClaudeWebAccount.parseUsage(try await read("/api/organizations/\(organization)/usage"), identity: metadata.identity).quota }
            catch is CancellationError { throw CancellationError() }
            catch ProviderQuotaError.signedOut { throw ProviderQuotaError.signedOut }
            catch { /* Keep the verified email/plan when the provider exposes no numeric limits. */ }
        }
        let after = try ClaudeWebAccount.parseAPI(account: try await read("/api/account"), organizations: organizations,
            selectedOrganizationID: cookie.organizationID, emailHint: account.emailHint)
        guard metadata.identity.matches(after.identity), metadata.identity.planType == after.identity.planType,
              cookie.fingerprint == (try ClaudeDesktopCookies.fingerprint(userData: home)) else { throw ProviderQuotaError.identityChanged }
        try Task.checkCancellation()
        try repository.validateClaudeOwnership(for: account.id)
        let scoped = CodexIdentity(email: after.identity.email, planType: after.identity.planType,
            accountId: "claudeDesktop:" + (after.identity.accountId ?? "") + ":" + (metadata.organizationID ?? "unknown"))
        return CodexConnection(identity: scoped, quota: quota, identityFetchedAt: Date(), providerSessionKind: "claudeDesktop")
    }
    fileprivate nonisolated static func safeStoragePassword(interactive: Bool) throws -> Data {
        let context = LAContext(); context.interactionNotAllowed = !interactive
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage", kSecAttrAccount as String: "Claude",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data, !data.isEmpty else { throw ClaudeDesktopQuotaError.accessRequired }
        return data
    }
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static func request(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// One OS authorization per manager session also covers subsequent background
/// quota reads. The key stays in memory and never enters persisted app data.
private final class ClaudeSafeStorageAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Data?
    func read(interactive: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let key = try ClaudeDesktopQuotaService.safeStoragePassword(interactive: interactive)
        cached = key
        return key
    }
}
