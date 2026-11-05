import Foundation

/// The Desktop project registry and local conversation store are shared together.
/// Authentication remains in each profile's separate .gemini directory.
public struct SharedAntigravityWorkspace {
    public let repository: ProfileRepository
    public let sourceHome: URL
    private let fm = FileManager.default
    private let paths = ["config/projects", "antigravity"]
    private struct Binding: Codable {
        let version: Int
        let source: String
        let originals: [Bool]
    }

    public init(repository: ProfileRepository, sourceHome: URL? = nil) {
        self.repository = repository
        self.sourceHome = (sourceHome ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
    }

    private func profile(_ account: Account) -> URL { repository.antigravityProfileURL(for: account.id) }
    private func marker(_ account: Account) -> URL { profile(account).appendingPathComponent("shared-projects.json") }
    private func source(_ path: String) -> URL { sourceHome.appendingPathComponent(".gemini").appendingPathComponent(path) }
    private func destination(_ account: Account, _ path: String) -> URL {
        repository.antigravityHomeURL(for: account.id).appendingPathComponent(".gemini").appendingPathComponent(path)
    }
    private func backup(_ account: Account, _ index: Int) -> URL {
        profile(account).appendingPathComponent("SharedProjectsBackup/\(index)")
    }
    private func kind(_ url: URL) throws -> FileAttributeType? {
        do { return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    private func directory(_ url: URL) throws {
        if try kind(url) == nil {
            try directory(url.deletingLastPathComponent())
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard try kind(url) == .typeDirectory else { throw AntigravityProfileError.unsafeStorage }
        // Reject redirected parents, including paths outside the managed profile.
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            // Foundation standardizes /private/var and /private/tmp to the
            // system aliases, including temporary fixture/profile roots.
            let systemAlias = ["/var", "/tmp"].contains(parent.path)
                && (try? fm.destinationOfSymbolicLink(atPath: parent.path)) == "private/" + parent.lastPathComponent
            guard try kind(parent) == .typeDirectory || systemAlias else { throw AntigravityProfileError.unsafeStorage }
            parent.deleteLastPathComponent()
        }
    }
    private func readBinding(_ account: Account) throws -> Binding? {
        let file = marker(account)
        guard let type = try kind(file) else { return nil }
        guard type == .typeRegular,
              let binding = try? JSONDecoder().decode(Binding.self, from: Data(contentsOf: file)),
              binding.version == 1, binding.source == sourceHome.path, binding.originals.count == paths.count else {
            throw AntigravityProfileError.unsafeStorage
        }
        return binding
    }
    private func verifiedLink(_ url: URL, target: URL) throws -> Bool {
        guard try kind(url) == .typeSymbolicLink else { return false }
        guard url.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL else {
            throw AntigravityProfileError.unsafeStorage
        }
        return true
    }

    public func isPrepared(_ account: Account) -> Bool { fm.fileExists(atPath: marker(account).path) }

    public func prepare(_ account: Account) throws {
        guard account.usesIsolatedAntigravity else { return }
        try repository.validateAntigravityOwnership(for: account.id)
        if !account.sharesAntigravityProjects {
            try restore(account)
            return
        }
        let home = repository.antigravityHomeURL(for: account.id).standardizedFileURL.path
        guard !sourceHome.path.hasPrefix(home + "/"), !home.hasPrefix(sourceHome.path + "/.gemini/"),
              sourceHome.path != home else { throw AntigravityProfileError.unsafeStorage }
        for path in paths { try directory(source(path)) }

        var binding = try readBinding(account)
        if binding == nil {
            for path in paths {
                let local = destination(account, path)
                if try kind(local) != nil { try directory(local) }
            }
            let projects = destination(account, paths[0])
            let data = destination(account, paths[1])
            var copies: [(URL, URL)] = []
            try planCopies(projects, source(paths[0]), into: &copies)
            for name in ["conversations", "brain", "scratch", "annotations"] {
                try planCopies(data.appendingPathComponent(name), source(paths[1]).appendingPathComponent(name), into: &copies)
            }
            for (from, to) in copies {
                try directory(to.deletingLastPathComponent())
                try fm.copyItem(at: from, to: to)
            }
            let originals = try paths.map { try kind(destination(account, $0)) != nil }
            let value = Binding(version: 1, source: sourceHome.path, originals: originals)
            try JSONEncoder().encode(value).write(to: marker(account), options: .atomic)
            binding = value
        }
        guard let binding else { throw AntigravityProfileError.unsafeStorage }
        try directory(profile(account).appendingPathComponent("SharedProjectsBackup"))
        for (index, path) in paths.enumerated() {
            let local = destination(account, path), saved = backup(account, index), target = source(path)
            try directory(local.deletingLastPathComponent())
            if try verifiedLink(local, target: target) { continue }
            if let type = try kind(local) {
                guard type == .typeDirectory, try kind(saved) == nil, binding.originals[index] else {
                    throw AntigravityProfileError.unsafeStorage
                }
                try fm.moveItem(at: local, to: saved)
            } else if binding.originals[index], try kind(saved) != .typeDirectory {
                throw AntigravityProfileError.unsafeStorage
            }
            try fm.createSymbolicLink(at: local, withDestinationURL: target)
        }
    }

    private func planCopies(_ from: URL, _ to: URL, into copies: inout [(URL, URL)]) throws {
        guard let type = try kind(from) else { return }
        guard type == .typeDirectory else { throw AntigravityProfileError.unsafeStorage }
        if let targetType = try kind(to), targetType != .typeDirectory { throw AntigravityProfileError.unsafeStorage }
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
            let target = to.appendingPathComponent(item.lastPathComponent)
            switch try kind(item) {
            case .typeDirectory:
                try planCopies(item, target, into: &copies)
            case .typeRegular:
                if let targetType = try kind(target) {
                    guard targetType == .typeRegular else { throw AntigravityProfileError.unsafeStorage }
                    if !fm.contentsEqual(atPath: item.path, andPath: target.path) {
                        // JSON formatting differences do not make two project definitions conflict.
                        let lhs = try? JSONSerialization.jsonObject(with: Data(contentsOf: item)) as? NSDictionary
                        let rhs = try? JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? NSDictionary
                        guard item.pathExtension == "json", let lhs, let rhs, lhs == rhs else {
                            throw AntigravityProfileError.sharedHistoryConflict
                        }
                    }
                } else { copies.append((item, target)) }
            default: throw AntigravityProfileError.unsafeStorage
            }
        }
    }

    private func restore(_ account: Account) throws {
        guard let binding = try readBinding(account) else { return }
        try directory(profile(account).appendingPathComponent("SharedProjectsBackup"))
        for (index, path) in paths.enumerated() {
            let local = destination(account, path), saved = backup(account, index)
            if try verifiedLink(local, target: source(path)) { try fm.removeItem(at: local) }
            if try kind(saved) != nil {
                guard try kind(saved) == .typeDirectory, try kind(local) == nil else { throw AntigravityProfileError.unsafeStorage }
                try directory(saved)
                try fm.moveItem(at: saved, to: local)
            } else if try kind(local) == nil {
                guard !binding.originals[index] else { throw AntigravityProfileError.unsafeStorage }
                try directory(local)
            } else if try kind(local) != .typeDirectory { throw AntigravityProfileError.unsafeStorage }
        }
        try fm.removeItem(at: marker(account))
    }

    /// Native metadata indexes may be memory-only. Index every saved local ID
    /// once per backend, including conversations created after sharing began.
    public func conversationIDs() throws -> [String] {
        let folder = source("antigravity/conversations")
        guard try kind(folder) != nil else { return [] }
        try directory(folder)
        return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap { file in
            guard file.pathExtension == "db", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            guard try kind(file) == .typeRegular else { throw AntigravityProfileError.unsafeStorage }
            return id.uuidString.lowercased()
        }.sorted()
    }
}
