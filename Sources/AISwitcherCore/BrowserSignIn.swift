import Foundation

public enum BrowserSignIn {
    public static let antigravityURLPrefix = "ANTIGRAVITY_OPEN_URL: "
    public static let antigravityBrowserHost = "ANTIGRAVITY_VSCODE_HOST"

    public static func antigravityURL(from line: String) throws -> URL? {
        guard line.hasPrefix(antigravityURLPrefix) else { return nil }
        let value = String(line.dropFirst(antigravityURLPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 16_384, let url = URL(string: value),
              url.scheme == "https", url.host?.lowercased() == "accounts.google.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value, !state.isEmpty,
              let redirect = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let callback = URL(string: redirect), callback.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]"].contains(callback.host?.lowercased() ?? ""),
              callback.user == nil, callback.password == nil,
              let port = callback.port, (1024...65535).contains(port) else {
            throw ProviderQuotaError.invalidResponse
        }
        return url
    }
}
