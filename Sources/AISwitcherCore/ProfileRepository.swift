import Foundation
import Darwin

/// Stores labels, a confirmed Codex identity, and cached quota. Never reads tokens.
public struct ProfileRepository: Sendable {
    public let root: URL
    public let desktopBackendBase: URL
    public var metadataURL: URL { root.appendingPathComponent("accounts.json") }
    public var profilesURL: URL { root.appendingPathComponent("Profiles", isDirectory: true) }
    public var codexURL: URL { root.appendingPathComponent("Codex", isDirectory: true) }
    public var desktopURL: URL { root.appendingPathComponent("Desktop", isDirectory: true) }

    public init(root: URL, desktopBackendBase: URL? = nil) {
        self.root = root.standardizedFileURL
        // macOS Unix sockets have short path limits. Keep backend homes short
        // and persistent; Electron UI data can stay in Application Support.
        self.desktopBackendBase = desktopBackendBase ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aisw")
    }

    public func desktopProfileURL(for id: UUID) -> URL { desktopURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func desktopUserDataURL(for id: UUID) -> URL { desktopProfileURL(for: id).appendingPathComponent("UserData", isDirectory: true) }
    public func desktopHomeURL(for id: UUID) -> URL {
        desktopBackendBase.appendingPathComponent(DesktopLaunch.profileKey(root: root, id: id), isDirectory: true)
    }

    public func validateDesktopOwnership(for id: UUID) throws {
        let home = desktopHomeURL(for: id)
        guard FileManager.default.fileExists(atPath: home.path) else { return }
        try validateOwnedDirectory(home)
        let marker = home.appendingPathComponent("ai-switcher-profile.json")
        guard let value = try? JSONDecoder().decode(DesktopOwner.self, from: Data(contentsOf: marker)),
              value.root == root.path, value.id == id else { throw DesktopProfileError.unsafeStorage }
    }

    public func prepareDesktopProfile(for id: UUID) throws {
        let home = desktopHomeURL(for: id)
        guard home.appendingPathComponent(DesktopLaunch.socketRelativePath).path.utf8.count < 104 else {
            throw DesktopProfileError.socketPathTooLong
        }
        try prepareDirectory(root)
        for directory in [desktopBackendBase, desktopURL, desktopProfileURL(for: id), desktopUserDataURL(for: id)] {
            if FileManager.default.fileExists(atPath: directory.path) { try validateOwnedDirectory(directory) }
            try prepareDirectory(directory)
        }
        if FileManager.default.fileExists(atPath: home.path) { try validateDesktopOwnership(for: id) }
        else {
            try prepareDirectory(home)
            let marker = home.appendingPathComponent("ai-switcher-profile.json")
            try JSONEncoder().encode(DesktopOwner(root: root.path, id: id)).write(to: marker, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        // Daemon launch overrides are not a substitute for its durable config.
        let config = home.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            try "cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n".write(to: config, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        try home.path.write(to: desktopProfileURL(for: id).appendingPathComponent("backend-location.txt"), atomically: true, encoding: .utf8)
    }

    private struct DesktopOwner: Codable { let root: String; let id: UUID }

    private func validateOwnedDirectory(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            throw DesktopProfileError.unsafeStorage
        }
    }

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
    /// The caller must first ensure all profile applications and backends have stopped.
    public func remove(_ id: UUID, from snapshot: AccountSnapshot) throws -> AccountSnapshot {
        let fm = FileManager.default
        try validateDesktopOwnership(for: id)
        var moved: [(source: URL, staged: URL)] = []
        do {
            for source in [profileURL(for: id), codexHomeURL(for: id), desktopProfileURL(for: id), desktopHomeURL(for: id)] where fm.fileExists(atPath: source.path) {
                let staged = source.deletingLastPathComponent().appendingPathComponent(".removed-\(UUID().uuidString)")
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
        for item in moved { try removeOwnedTree(item.staged) }
        return updated
    }

    /// ChatGPT creates owner-read-only runtime directories. Make only owned
    /// directories traversable/removable, never following links or changing files.
    private func removeOwnedTree(_ root: URL) throws {
        var directories = [root]
        while let directory = directories.popLast() {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw DesktopProfileError.unsafeStorage }
            let mode = (attributes[.posixPermissions] as? Int ?? 0) | 0o700
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if try FileManager.default.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType == .typeDirectory {
                    directories.append(child)
                }
            }
        }
        try FileManager.default.removeItem(at: root)
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
