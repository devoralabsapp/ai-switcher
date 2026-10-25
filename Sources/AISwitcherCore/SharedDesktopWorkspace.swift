import Foundation
import SQLite3
import Darwin

public enum SharedWorkspaceError: LocalizedError {
    case unsafeStorage, privateHistory, databaseUnavailable, unsupportedConfiguration

    public var errorDescription: String? {
        switch self {
        case .unsafeStorage:
            return L10n.text("The local workspace paths could not be verified. No existing workspace data was replaced.")
        case .privateHistory:
            return L10n.text("This profile already has private local history. Its data was kept. Use a new profile to share the existing ChatGPT workspace.")
        case .databaseUnavailable:
            return L10n.text("Could not access the local history database. Close this profile and try again.")
        case .unsupportedConfiguration:
            return L10n.text("The existing ChatGPT history location could not be resolved. Check its sqlite_home setting.")
        }
    }
}

/// Shares local work storage, never authentication or browser/UI login storage.
/// Call preparation/restoration only while this profile's UI and backend are stopped.
public struct SharedDesktopWorkspace {
    public let repository: ProfileRepository
    public let sourceHome: URL
    public let sourceUserData: URL
    private let fm = FileManager.default
    private static let stateName = ".codex-global-state.json"
    private static let markerName = "ai-switcher-workspace.json"
    private static let transcriptDirectories = ["sessions", "archived_sessions"]
    private static let metadataKeys = [
        "local-projects", "project-order", "project-appearances", "pinned-project-ids",
        "projectless-thread-ids", "thread-projectless-output-directories", "thread-workspace-root-hints",
        "thread-project-assignments", "thread-project-membership-host-ids", "thread-writable-roots",
        "pinned-thread-ids", "sidebar-project-thread-orders", "electron-managed-worktree-archives",
        "app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host",
        "app-server-migrated-pinned-thread-ids-by-host",
    ]

    private struct Binding: Codable {
        let version: Int
        let sourceHome: URL
        let databaseHome: URL
        let artifactSessions: URL?
    }

    public init(repository: ProfileRepository, sourceHome: URL? = nil, sourceUserData: URL? = nil) {
        self.repository = repository
        self.sourceHome = (sourceHome ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).standardizedFileURL
        self.sourceUserData = (sourceUserData ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex")).standardizedFileURL
    }

    public func isPrepared(_ id: UUID) -> Bool {
        fm.fileExists(atPath: repository.desktopHomeURL(for: id).appendingPathComponent(Self.markerName).path)
    }

    @discardableResult
    public func prepare(_ id: UUID) throws -> URL {
        try repository.validateDesktopOwnership(for: id)
        let home = repository.desktopHomeURL(for: id)
        try ownedDirectory(home)
        guard home != sourceHome, !sourceHome.path.hasPrefix(home.path + "/"),
              !home.path.hasPrefix(sourceHome.path + "/") else { throw SharedWorkspaceError.unsafeStorage }
        try makeDirectory(sourceHome)
        let databaseHome = try resolveDatabaseHome()
        try makeDirectory(databaseHome)
        let existing = try binding(id)
        if let existing {
            guard existing.sourceHome == sourceHome, existing.databaseHome == databaseHome else {
                throw SharedWorkspaceError.unsafeStorage
            }
            try validateLinks(id, home: home, source: sourceHome, artifactSessions: existing.artifactSessions)
            try refreshMetadata(id)
            if existing.artifactSessions == nil {
                var moved: [(URL, URL)] = [], linked: [URL] = []
                do {
                    let artifacts = try prepareArtifacts(id, moved: &moved, linked: &linked)
                    try writeBinding(Binding(version: 1, sourceHome: sourceHome, databaseHome: databaseHome, artifactSessions: artifacts), home: home)
                } catch {
                    for path in linked { try? fm.removeItem(at: path) }
                    for (path, saved) in moved.reversed() { try? fm.moveItem(at: saved, to: path) }
                    throw error
                }
            }
            return databaseHome
        }

        // Never hide or overwrite private chats when opting in. Existing profiles
        // without chats can opt in; private history remains recoverable in place.
        if let db = try stateDatabase(in: home), try databaseHasThreads(db) { throw SharedWorkspaceError.privateHistory }
        for name in Self.transcriptDirectories {
            let path = home.appendingPathComponent(name)
            if let kind = try type(path) {
                guard kind == .typeDirectory else { throw SharedWorkspaceError.unsafeStorage }
                guard try fm.contentsOfDirectory(atPath: path.path).isEmpty else { throw SharedWorkspaceError.privateHistory }
            }
            try makeDirectory(sourceHome.appendingPathComponent(name))
        }

        let backup = home.appendingPathComponent("ai-switcher-workspace-backup", isDirectory: true)
        try makeDirectory(backup)
        let state = home.appendingPathComponent(Self.stateName)
        let original = try readObject(state)
        try writeObject(original, to: backup.appendingPathComponent(Self.stateName))
        var moved: [(URL, URL)] = []
        var linked: [URL] = []
        do {
            for name in Self.transcriptDirectories {
                let path = home.appendingPathComponent(name), saved = backup.appendingPathComponent(name)
                if try type(path) != nil { try fm.moveItem(at: path, to: saved); moved.append((path, saved)) }
                try fm.createSymbolicLink(at: path, withDestinationURL: sourceHome.appendingPathComponent(name))
                linked.append(path)
            }
            let artifacts = try prepareArtifacts(id, moved: &moved, linked: &linked)
            try refreshMetadata(id)
            try writeBinding(Binding(version: 1, sourceHome: sourceHome, databaseHome: databaseHome, artifactSessions: artifacts), home: home)
        } catch {
            for path in linked { try? fm.removeItem(at: path) }
            for (path, saved) in moved.reversed() { try? fm.moveItem(at: saved, to: path) }
            try? writeObject(original, to: state)
            throw error
        }
        return databaseHome
    }

    public func restorePrivateWorkspace(_ id: UUID) throws {
        guard let existing = try binding(id) else { return }
        let home = repository.desktopHomeURL(for: id)
        try validateLinks(id, home: home, source: existing.sourceHome, artifactSessions: existing.artifactSessions)
        try archiveMetadata(id)
        let backup = home.appendingPathComponent("ai-switcher-workspace-backup")
        var state = try readObject(home.appendingPathComponent(Self.stateName))
        let previous = try readObject(backup.appendingPathComponent(Self.stateName))
        for key in Self.metadataKeys { state[key] = previous[key] }
        try writeObject(state, to: home.appendingPathComponent(Self.stateName))
        for name in Self.transcriptDirectories {
            let path = home.appendingPathComponent(name), saved = backup.appendingPathComponent(name)
            try fm.removeItem(at: path)
            if try type(saved) != nil { try fm.moveItem(at: saved, to: path) }
        }
        if existing.artifactSessions != nil {
            let path = repository.desktopUserDataURL(for: id).appendingPathComponent("artifact-sessions")
            let saved = repository.desktopProfileURL(for: id).appendingPathComponent("WorkspaceBackup/artifact-sessions")
            try fm.removeItem(at: path)
            if try type(saved) != nil { try fm.moveItem(at: saved, to: path) }
        }
        try fm.removeItem(at: home.appendingPathComponent(Self.markerName))
    }

    /// Preserve sidebar metadata and canonical transcript paths before a profile
    /// closes, unlinks shared storage, or is deleted. Never writes the default UI state.
    public func archiveMetadata(_ id: UUID) throws {
        guard let existing = try binding(id) else { return }
        let home = repository.desktopHomeURL(for: id)
        try validateLinks(id, home: home, source: existing.sourceHome, artifactSessions: existing.artifactSessions)
        let directory = repository.root.appendingPathComponent("SharedWorkspaceMetadata", isDirectory: true)
        try makeDirectory(directory)
        let state = try readObject(home.appendingPathComponent(Self.stateName))
        try writeObject(state.filter { Self.metadataKeys.contains($0.key) },
                        to: directory.appendingPathComponent(id.uuidString + ".json"))
        if let db = try stateDatabase(in: existing.databaseHome) {
            try canonicalizeTranscripts(database: db, home: home, source: existing.sourceHome)
        }
    }

    private func refreshMetadata(_ id: UUID) throws {
        let home = repository.desktopHomeURL(for: id), stateURL = home.appendingPathComponent(Self.stateName)
        var state = try readObject(stateURL)
        let archives = repository.root.appendingPathComponent("SharedWorkspaceMetadata")
        var sources: [URL] = []
        if try type(archives) != nil {
            try ownedDirectory(archives)
            sources += try fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)
                .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for account in try repository.load().accounts where account.id != id && account.usesSharedLocalWorkspace {
            try repository.validateDesktopOwnership(for: account.id)
            sources.append(repository.desktopHomeURL(for: account.id).appendingPathComponent(Self.stateName))
        }
        sources.append(sourceHome.appendingPathComponent(Self.stateName))
        for url in sources {
            let incoming = try readObject(url)
            for key in Self.metadataKeys {
                if let value = incoming[key] { state[key] = Self.merged(state[key], value) }
            }
        }
        try writeObject(state, to: stateURL)
    }

    private static func merged(_ current: Any?, _ incoming: Any) -> Any {
        if let a = current as? [String: Any], let b = incoming as? [String: Any] {
            return b.reduce(into: a) { $0[$1.key] = merged($0[$1.key], $1.value) }
        }
        if let a = current as? [Any], let b = incoming as? [Any] {
            return b.reduce(into: a) { list, value in
                if !list.contains(where: { ($0 as? NSObject)?.isEqual(value) == true }) { list.append(value) }
            }
        }
        return incoming
    }

    private func binding(_ id: UUID) throws -> Binding? {
        let marker = repository.desktopHomeURL(for: id).appendingPathComponent(Self.markerName)
        guard try type(marker) != nil else { return nil }
        try repository.validateDesktopOwnership(for: id)
        try ownedFile(marker)
        let result = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: marker))
        guard result.version == 1, result.sourceHome.isFileURL, result.databaseHome.isFileURL,
              result.sourceHome == result.sourceHome.standardizedFileURL,
              result.databaseHome == result.databaseHome.standardizedFileURL else { throw SharedWorkspaceError.unsafeStorage }
        try ownedDirectory(result.sourceHome)
        try ownedDirectory(result.databaseHome)
        return result
    }

    private func validateLinks(_ id: UUID, home: URL, source: URL, artifactSessions: URL?) throws {
        for name in Self.transcriptDirectories {
            let path = home.appendingPathComponent(name)
            guard try type(path) == .typeSymbolicLink,
                  try fm.destinationOfSymbolicLink(atPath: path.path) == source.appendingPathComponent(name).path else {
                throw SharedWorkspaceError.unsafeStorage
            }
        }
        if let artifactSessions {
            try ownedDirectory(artifactSessions)
            try ownedDirectory(repository.desktopUserDataURL(for: id))
            let path = repository.desktopUserDataURL(for: id).appendingPathComponent("artifact-sessions")
            guard try type(path) == .typeSymbolicLink,
                  try fm.destinationOfSymbolicLink(atPath: path.path) == artifactSessions.path else { throw SharedWorkspaceError.unsafeStorage }
        }
    }

    private func prepareArtifacts(_ id: UUID, moved: inout [(URL, URL)], linked: inout [URL]) throws -> URL {
        try makeDirectory(sourceUserData)
        let source = sourceUserData.appendingPathComponent("artifact-sessions", isDirectory: true)
        try makeDirectory(source)
        let userData = repository.desktopUserDataURL(for: id)
        try ownedDirectory(userData)
        let path = userData.appendingPathComponent("artifact-sessions")
        guard path != source, !source.path.hasPrefix(userData.path + "/") else { throw SharedWorkspaceError.unsafeStorage }
        if try type(path) != nil {
            try ownedDirectory(path)
            let backup = repository.desktopProfileURL(for: id).appendingPathComponent("WorkspaceBackup")
            try makeDirectory(backup)
            let saved = backup.appendingPathComponent("artifact-sessions")
            guard try type(saved) == nil else { throw SharedWorkspaceError.unsafeStorage }
            try fm.moveItem(at: path, to: saved)
            moved.append((path, saved))
        }
        try fm.createSymbolicLink(at: path, withDestinationURL: source)
        linked.append(path)
        return source
    }

    private func writeBinding(_ value: Binding, home: URL) throws {
        let marker = home.appendingPathComponent(Self.markerName)
        try JSONEncoder().encode(value).write(to: marker, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private func resolveDatabaseHome() throws -> URL {
        let config = sourceHome.appendingPathComponent("config.toml")
        if try type(config) != nil {
            try ownedFile(config)
            for raw in try String(contentsOf: config).components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                guard let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces) == "sqlite_home" else { continue }
                let remainder = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                let pattern = #"^("(?:\\.|[^"\\])*"|'[^']*')\s*(?:#.*)?$"#
                let regex = try NSRegularExpression(pattern: pattern)
                guard let match = regex.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
                      let range = Range(match.range(at: 1), in: remainder) else { throw SharedWorkspaceError.unsupportedConfiguration }
                let literal = String(remainder[range])
                let value: String
                if literal.hasPrefix("\"") {
                    let decoder = JSONDecoder()
                    guard let parsed = try? decoder.decode(String.self, from: Data(literal.utf8)) else { throw SharedWorkspaceError.unsupportedConfiguration }
                    value = parsed
                } else if literal.hasPrefix("'"), literal.hasSuffix("'") { value = String(literal.dropFirst().dropLast()) }
                else { throw SharedWorkspaceError.unsupportedConfiguration }
                let expanded = (value as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else { throw SharedWorkspaceError.unsupportedConfiguration }
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        return sourceHome
    }

    private func stateDatabase(in directory: URL) throws -> URL? {
        guard try type(directory) != nil else { return nil }
        try ownedDirectory(directory)
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^state_[0-9]+\.sqlite$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }.first
    }

    private func databaseHasThreads(_ url: URL) throws -> Bool {
        try database(url, write: false) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT EXISTS(SELECT 1 FROM threads LIMIT 1)", -1, &statement, nil) == SQLITE_OK else { throw SharedWorkspaceError.databaseUnavailable }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw SharedWorkspaceError.databaseUnavailable }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    private func canonicalizeTranscripts(database url: URL, home: URL, source: URL) throws {
        try database(url, write: true) { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw SharedWorkspaceError.databaseUnavailable }
            do {
                for name in Self.transcriptDirectories {
                    let old = home.appendingPathComponent(name).path + "/", new = source.appendingPathComponent(name).path + "/"
                    var statement: OpaquePointer?
                    let sql = "UPDATE threads SET rollout_path = ?1 || substr(rollout_path, length(?2) + 1) WHERE substr(rollout_path, 1, length(?2)) = ?2"
                    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SharedWorkspaceError.databaseUnavailable }
                    defer { sqlite3_finalize(statement) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(statement, 1, new, -1, transient)
                    sqlite3_bind_text(statement, 2, old, -1, transient)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw SharedWorkspaceError.databaseUnavailable }
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw SharedWorkspaceError.databaseUnavailable }
            } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
        }
    }

    private func database<T>(_ url: URL, write: Bool, operation: (OpaquePointer) throws -> T) throws -> T {
        try ownedFile(url)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, write ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw SharedWorkspaceError.databaseUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        return try operation(db)
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        guard try type(url) != nil else { return [:] }
        try ownedFile(url)
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw SharedWorkspaceError.unsafeStorage }
        return value
    }

    private func writeObject(_ value: [String: Any], to url: URL) throws {
        if try type(url) != nil { try ownedFile(url) }
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func makeDirectory(_ url: URL) throws {
        if try type(url) != nil { try ownedDirectory(url) }
        else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }

    private func ownedDirectory(_ url: URL) throws { try owned(url, kind: .typeDirectory) }
    private func ownedFile(_ url: URL) throws { try owned(url, kind: .typeRegular) }
    private func owned(_ url: URL, kind: FileAttributeType) throws {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == kind,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw SharedWorkspaceError.unsafeStorage }
    }
    private func type(_ url: URL) throws -> FileAttributeType? {
        do { return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
}
