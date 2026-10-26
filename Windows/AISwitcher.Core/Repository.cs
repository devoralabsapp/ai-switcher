using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AISwitcher.Core;

public sealed class Repository {
    public string Root { get; }
    public string BackendBase { get; }
    public string MetadataPath => Path.Combine(Root, "accounts.json");
    public string PreferencesPath => Path.Combine(Root, "preferences.json");
    public Repository(string root, string? backendBase = null) {
        Root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        BackendBase = Path.GetFullPath(backendBase ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".aisw"));
    }
    public string ProfilePath(Account account) => Path.Combine(Root, account.EffectiveMode == LaunchMode.Browser ? "Profiles" : account.Agent == Agent.Claude ? "Claude" : "Desktop", account.Id.ToString("D"));
    public string DataPath(Account account) => account.EffectiveMode == LaunchMode.Browser ? ProfilePath(account) : Path.Combine(ProfilePath(account), "UserData");
    public string BackendPath(Guid id) => Path.Combine(BackendBase, "win-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Root + "\n" + id))).ToLowerInvariant()[..20]);
    public string QuotaHome(Account account) => account.UsesCodexDesktop ? BackendPath(account.Id) : Path.Combine(Root, "Codex", account.Id.ToString("D"));
    public string CodeConfig(Account account) => Path.Combine(ProfilePath(account), "CodeConfig");
    static StringComparison Comparison => OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
    public static void RejectLinks(string path) {
        try { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new AppError("Profile storage could not be verified. Reconnect and restart are disabled to preserve its data."); }
        catch (FileNotFoundException) { } catch (DirectoryNotFoundException) { }
    }
    static void EnsureDirectory(string directory) { RejectLinks(directory); Directory.CreateDirectory(directory); RejectLinks(directory); }
    public void CheckRoot() { RejectLinks(Root); if(File.Exists(Root))throw new AppError("Could not read data. The existing file has been preserved."); }
    public FileStream AcquireLease() { CheckRoot(); EnsureDirectory(Root); return new FileStream(Path.Combine(Root, ".manager.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
    public Snapshot Load() {
        CheckRoot(); RejectLinks(MetadataPath);
        if (Directory.Exists(MetadataPath)) throw new AppError("Could not read data. The existing file has been preserved.");
        if (!File.Exists(MetadataPath)) return new();
        var value = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(MetadataPath), Json.Options) ?? throw new AppError("Could not read data. The existing file has been preserved.");
        value.Validate(); return value;
    }
    public Preferences LoadPreferences() {
        CheckRoot(); RejectLinks(PreferencesPath);
        var value = File.Exists(PreferencesPath) ? JsonSerializer.Deserialize<Preferences>(File.ReadAllText(PreferencesPath), Json.Options) ?? throw new AppError("Could not read data. The existing file has been preserved.") : new();
        value.Normalize(); return value;
    }
    public void Save(Snapshot value) { value.Validate(); Write(MetadataPath, value); }
    public void SavePreferences(Preferences value) { value.Normalize(); Write(PreferencesPath, value); }
    void Write<T>(string target, T value) {
        CheckRoot(); EnsureDirectory(Root); RejectLinks(target);
        var temporary = Path.Combine(Root, ".write-" + Guid.NewGuid().ToString("N"));
        try {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) {
                JsonSerializer.Serialize(file, value, Json.Options); file.Flush(true);
            }
            File.Move(temporary, target, true);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    sealed record Owner(string Root, Guid Id);
    public void ValidateOwned(string home, Guid id) {
        CheckRoot(); RejectLinks(home);
        if (!Directory.Exists(home)) return;
        RejectLinks(Path.GetDirectoryName(home)!);
        var marker = Path.Combine(home, "ai-switcher-profile.json"); RejectLinks(marker);
        Owner? value;
        try { value = JsonSerializer.Deserialize<Owner>(File.ReadAllText(marker), Json.Options); }
        catch { throw new AppError("The profile ownership marker does not match. Data was preserved."); }
        if (value?.Id != id || !string.Equals(value.Root, Root, Comparison)) throw new AppError("The profile ownership marker does not match. Data was preserved.");
    }
    public void PrepareOwned(string home, Guid id) {
        CheckRoot(); EnsureDirectory(Root); EnsureDirectory(Path.GetDirectoryName(home)!);
        if (Directory.Exists(home)) { ValidateOwned(home, id); return; }
        EnsureDirectory(home);
        File.WriteAllText(Path.Combine(home, "ai-switcher-profile.json"), JsonSerializer.Serialize(new Owner(Root, id), Json.Options));
    }
    public void PrepareProfile(Account account) {
        account.Validate(); PrepareOwned(ProfilePath(account), account.Id);
        if (account.EffectiveMode == LaunchMode.Desktop) EnsureDirectory(DataPath(account));
        if (account.Agent == Agent.Claude && account.EffectiveMode == LaunchMode.Desktop) EnsureDirectory(CodeConfig(account));
    }
    public void PrepareQuota(Account account) {
        if (!account.Agent.HasQuota()) throw new AppError("Quota is not available for this agent.");
        var home = QuotaHome(account); PrepareOwned(home, account.Id);
        var config = Path.Combine(home, "config.toml"); RejectLinks(config);
        if (!File.Exists(config)) File.WriteAllText(config, "cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n");
    }
    public IEnumerable<string> AllProfilePaths(Guid id) => new[] { "Profiles", "Claude", "Desktop", "Codex" }.Select(x => Path.Combine(Root, x, id.ToString("D"))).Append(BackendPath(id));
    public Snapshot Remove(Account account, Snapshot snapshot) {
        var moved = new List<(string Source, string Staged)>();
        foreach (var path in AllProfilePaths(account.Id)) ValidateOwned(path, account.Id);
        try {
            foreach (var path in AllProfilePaths(account.Id).Where(Directory.Exists)) {
                var staged = Path.Combine(Path.GetDirectoryName(path)!, ".removed-" + Guid.NewGuid().ToString("N"));
                Directory.Move(path, staged); moved.Add((path, staged));
            }
            var updated = snapshot with { Accounts = snapshot.Accounts.Where(x => x.Id != account.Id).ToList(), LastOpenedId = snapshot.LastOpenedId == account.Id ? null : snapshot.LastOpenedId };
            Save(updated);
            // Metadata is now durable. Cleanup failure must never restore deleted metadata.
            foreach (var item in moved) DeleteTree(item.Staged);
            return updated;
        } catch {
            // Restore staged directories only if metadata still references this account.
            bool stillReferenced;
            try { stillReferenced = Load().Accounts.Any(x => x.Id == account.Id); } catch { stillReferenced = true; }
            if (stillReferenced) foreach (var item in moved.AsEnumerable().Reverse()) if (Directory.Exists(item.Staged) && !Directory.Exists(item.Source)) Directory.Move(item.Staged, item.Source);
            throw;
        }
    }
    public static void DeleteTree(string root) {
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) { Directory.Delete(root); return; }
        foreach (var entry in Directory.EnumerateFileSystemEntries(root)) {
            var flags = File.GetAttributes(entry);
            if ((flags & FileAttributes.Directory) != 0) DeleteTree(entry);
            else { if ((flags & FileAttributes.ReparsePoint) == 0) File.SetAttributes(entry, flags & ~FileAttributes.ReadOnly); File.Delete(entry); }
        }
        Directory.Delete(root);
    }
}
