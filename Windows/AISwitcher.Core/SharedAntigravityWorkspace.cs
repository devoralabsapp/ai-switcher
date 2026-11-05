using System.Text.Json;

namespace AISwitcher.Core;

public sealed class SharedAntigravityWorkspace(Repository repository, string? sourceHome = null)
{
    public const string SessionRunning = "Close Antigravity Desktop and other shared Antigravity sessions before opening this shared workspace.";
    public const string Conflict = "A local project or conversation differs between Antigravity sessions. Its original data was kept. Close the sessions and resolve the duplicate before sharing.";
    readonly string home = Path.GetFullPath(sourceHome ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    static readonly string[] Paths = [Path.Combine("config", "projects"), "antigravity"];
    sealed record Binding(int Version, string Source, bool[] Originals);
    string Profile(Account account) => repository.ProfilePath(account);
    string Marker(Account account) => Path.Combine(Profile(account), "shared-projects.json");
    string Source(string path) => Path.Combine(home, ".gemini", path);
    string Destination(Account account, string path) => Path.Combine(AntigravityProfile.Home(repository, account), ".gemini", path);
    string Backup(Account account, int index) => Path.Combine(Profile(account), "SharedProjectsBackup", index.ToString());
    static readonly StringComparison Comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    static FileAttributes? Attributes(string path)
    {
        try { return File.GetAttributes(path); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    static void DirectoryPath(string path)
    {
        for (var parent = new DirectoryInfo(path); parent != null; parent = parent.Parent)
        {
            if (OperatingSystem.IsWindows()) Repository.RejectLinks(parent.FullName);
            if (File.Exists(parent.FullName)) throw new AppError("Profile storage could not be verified.");
        }
        Directory.CreateDirectory(path);
    }
    static void Write(string path, object value)
    {
        Repository.RejectLinks(path);
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew))
                JsonSerializer.Serialize(file, value);
            File.Move(temporary, path, true);
        }
        finally { File.Delete(temporary); }
    }
    Binding? ReadBinding(Account account)
    {
        Repository.RejectLinks(Marker(account));
        if (!File.Exists(Marker(account))) return null;
        var binding = JsonSerializer.Deserialize<Binding>(File.ReadAllText(Marker(account)));
        if (binding == null || binding.Version != 1 || !string.Equals(binding.Source, home, Comparison)
            || binding.Originals.Length != Paths.Length)
            throw new AppError("Profile storage could not be verified.");
        return binding;
    }
    bool VerifiedLink(string path, string target)
    {
        if (Attributes(path) is not { } flags || !flags.HasFlag(FileAttributes.ReparsePoint)) return false;
        var resolved = new DirectoryInfo(path).ResolveLinkTarget(true)?.FullName;
        if (!string.Equals(resolved, target, Comparison)) throw new AppError("Profile storage could not be verified.");
        return true;
    }
    public bool IsPrepared(Account account) => File.Exists(Marker(account));

    public async Task PrepareAsync(Account account, Func<string, string, Task> createLink)
    {
        if (!account.UsesPrivateAntigravity) return;
        AntigravityProfile.Validate(repository, account);
        if (!account.SharesAntigravityProjects)
        {
            Restore(account);
            return;
        }
        var localHome = AntigravityProfile.Home(repository, account);
        if (home.StartsWith(localHome + Path.DirectorySeparatorChar, Comparison) ||
            localHome.StartsWith(Path.Combine(home, ".gemini") + Path.DirectorySeparatorChar, Comparison) ||
            home.Equals(localHome, Comparison))
            throw new AppError("Profile storage could not be verified.");
        foreach (var path in Paths) DirectoryPath(Source(path));

        var binding = ReadBinding(account);
        if (binding == null)
        {
            foreach (var path in Paths)
            {
                var local = Destination(account, path);
                if (Attributes(local) != null) { Repository.RejectLinks(local); DirectoryPath(local); }
            }
            var copies = new List<(string From, string To)>();
            PlanCopies(Destination(account, Paths[0]), Source(Paths[0]), copies);
            var data = Destination(account, Paths[1]);
            foreach (var name in new[] { "conversations", "brain", "scratch", "annotations" })
                PlanCopies(Path.Combine(data, name), Path.Combine(Source(Paths[1]), name), copies);
            foreach (var copy in copies)
            {
                DirectoryPath(Path.GetDirectoryName(copy.To)!);
                File.Copy(copy.From, copy.To);
            }
            binding = new(1, home, Paths.Select(p => Attributes(Destination(account, p)) != null).ToArray());
            Write(Marker(account), binding);
        }
        DirectoryPath(Path.Combine(Profile(account), "SharedProjectsBackup"));
        for (var index = 0; index < Paths.Length; index++)
        {
            var local = Destination(account, Paths[index]);
            var saved = Backup(account, index);
            var target = Source(Paths[index]);
            DirectoryPath(Path.GetDirectoryName(local)!);
            if (VerifiedLink(local, target)) continue;
            if (Attributes(local) is { } flags)
            {
                if (!flags.HasFlag(FileAttributes.Directory) || Attributes(saved) != null || !binding.Originals[index])
                    throw new AppError("Profile storage could not be verified.");
                Directory.Move(local, saved);
            }
            else if (binding.Originals[index] && !Directory.Exists(saved))
                throw new AppError("Profile storage could not be verified.");
            await createLink(local, target);
            if (!VerifiedLink(local, target)) throw new AppError("Profile storage could not be verified.");
        }
    }

    static bool SameFile(string first, string second)
    {
        using var left = File.OpenRead(first);
        using var right = File.OpenRead(second);
        if (left.Length != right.Length) return false;
        var a = new byte[65536];
        var b = new byte[65536];
        int count;
        while ((count = left.Read(a)) > 0)
        {
            right.ReadExactly(b.AsSpan(0, count));
            if (!a.AsSpan(0, count).SequenceEqual(b.AsSpan(0, count))) return false;
        }
        return true;
    }
    static void PlanCopies(string from, string to, List<(string From, string To)> copies)
    {
        if (Attributes(from) is not { } flags) return;
        Repository.RejectLinks(from);
        if (!flags.HasFlag(FileAttributes.Directory)) throw new AppError("Profile storage could not be verified.");
        if (Attributes(to) != null)
        {
            Repository.RejectLinks(to);
            if (!Directory.Exists(to)) throw new AppError("Profile storage could not be verified.");
        }
        foreach (var item in Directory.EnumerateFileSystemEntries(from))
        {
            Repository.RejectLinks(item);
            var target = Path.Combine(to, Path.GetFileName(item));
            if (Directory.Exists(item)) { PlanCopies(item, target, copies); continue; }
            if (Attributes(target) == null) { copies.Add((item, target)); continue; }
            Repository.RejectLinks(target);
            if (Directory.Exists(target)) throw new AppError("Profile storage could not be verified.");
            if (SameFile(item, target)) continue;
            if (Path.GetExtension(item) == ".json")
            {
                var lhs = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(item));
                var rhs = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(target));
                if (System.Text.Json.Nodes.JsonNode.DeepEquals(lhs, rhs)) continue;
            }
            throw new AppError(Conflict);
        }
    }

    void Restore(Account account)
    {
        var binding = ReadBinding(account);
        if (binding == null) return;
        DirectoryPath(Path.Combine(Profile(account), "SharedProjectsBackup"));
        for (var index = 0; index < Paths.Length; index++)
        {
            var local = Destination(account, Paths[index]);
            var saved = Backup(account, index);
            if (VerifiedLink(local, Source(Paths[index]))) Directory.Delete(local);
            if (Attributes(saved) != null)
            {
                Repository.RejectLinks(saved);
                if (!Directory.Exists(saved) || Attributes(local) != null) throw new AppError("Profile storage could not be verified.");
                DirectoryPath(saved);
                Directory.Move(saved, local);
            }
            else if (Attributes(local) == null)
            {
                if (binding.Originals[index]) throw new AppError("Profile storage could not be verified.");
                DirectoryPath(local);
            }
            else
            {
                Repository.RejectLinks(local);
                if (!Directory.Exists(local)) throw new AppError("Profile storage could not be verified.");
            }
        }
        File.Delete(Marker(account));
    }

    // The native index may be memory-only: rebuild saved local IDs once per backend.
    public string[] ConversationIDs()
    {
        var folder = Source(Path.Combine("antigravity", "conversations"));
        if (Attributes(folder) == null) return [];
        Repository.RejectLinks(folder);
        DirectoryPath(folder);
        return Directory.EnumerateFiles(folder, "*.db").Select(file =>
        {
            Repository.RejectLinks(file);
            return Guid.TryParse(Path.GetFileNameWithoutExtension(file), out var id) ? id.ToString("D") : null;
        }).Where(id => id != null).Cast<string>().Order().ToArray();
    }
}
