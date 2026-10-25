import Foundation

/// Stores labels, a confirmed Codex identity, and cached quota. Never reads tokens.
public struct ProfileRepository: Sendable {
    public let root: URL
    public var metadataURL: URL { root.appendingPathComponent("accounts.json") }
    public var profilesURL: URL { root.appendingPathComponent("Profiles", isDirectory: true) }
    public var codexURL: URL { root.appendingPathComponent("Codex", isDirectory: true) }

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func profileURL(for id: UUID) -> URL {
        profilesURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func codexHomeURL(for id: UUID) -> URL {
        codexURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func prepareCodexHome(for id: UUID) throws -> URL {
        try prepareDirectory(root)
        try prepareDirectory(codexURL)
        let home = codexHomeURL(for: id)
        try prepareDirectory(home)
        return home
    }

    public func load() throws -> AccountSnapshot {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return AccountSnapshot() }
        let snapshot = try JSONDecoder().decode(AccountSnapshot.self, from: Data(contentsOf: metadataURL))
        try snapshot.validate()
        return snapshot
    }

    public func save(_ snapshot: AccountSnapshot) throws {
        try snapshot.validate()
        try prepareDirectory(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: metadataURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    public func prepareProfile(for id: UUID) throws -> URL {
        try prepareDirectory(root)
        try prepareDirectory(profilesURL)
        let url = profileURL(for: id)
        try prepareDirectory(url)
        return url
    }

    /// Stage the folder so a failed metadata save can restore the complete session.
    /// The caller must first ensure this browser profile has stopped.
    public func remove(_ id: UUID, from snapshot: AccountSnapshot) throws -> AccountSnapshot {
        let fm = FileManager.default
        var moved: [(source: URL, staged: URL)] = []
        do {
            for source in [profileURL(for: id), codexHomeURL(for: id)] where fm.fileExists(atPath: source.path) {
                let staged = root.appendingPathComponent(".removed-\(UUID().uuidString)")
                try fm.moveItem(at: source, to: staged)
                moved.append((source, staged))
            }
        } catch {
            for item in moved.reversed() { try? fm.moveItem(at: item.staged, to: item.source) }
            throw error
        }
        var updated = snapshot
        updated.accounts.removeAll { $0.id == id }
        if updated.lastOpenedID == id { updated.lastOpenedID = nil }
        do {
            try save(updated)
        } catch {
            for item in moved.reversed() { try? fm.moveItem(at: item.staged, to: item.source) }
            throw error
        }
        // If cleanup fails the error is surfaced and the caller reloads saved metadata.
        for item in moved { try fm.removeItem(at: item.staged) }
        return updated
    }

    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public enum BrowserLaunch {
    public static let chatURL = URL(string: "https://chatgpt.com/")!

    public static func arguments(profileURL: URL, url: URL = chatURL) -> [String] {
        return [
            "--user-data-dir=\(profileURL.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-mode",
            "--app=\(url.absoluteString)",
            "--window-size=1180,840",
        ]
    }

    public static func ownsProcess(arguments: [String], profileURL: URL) -> Bool {
        arguments.contains("--user-data-dir=\(profileURL.path)") && !arguments.contains { $0.hasPrefix("--type=") }
    }
}
