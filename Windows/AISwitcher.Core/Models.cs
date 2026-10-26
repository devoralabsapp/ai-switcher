using System.Globalization;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace AISwitcher.Core;

public enum Agent { Chatgpt, Claude, Gemini, Antigravity, Perplexity, Deepseek }
public enum LaunchMode { Desktop, Browser }
public enum Browser { Chrome, Edge, Brave }
public enum DefaultAction { OpenDesktop, ConnectSession }
public enum WorkspaceLayout { Cards, QuotaTable }
public enum SortKey { Name, PrimaryRemaining, SecondaryRemaining, NextReset, LastUpdated }
public static class Json {
    public static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true, Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };
}
public static class Agents {
    public static string Name(this Agent value) => value switch { Agent.Chatgpt => "ChatGPT", Agent.Deepseek => "DeepSeek", _ => value.ToString() };
    public static bool HasQuota(this Agent value) => value == Agent.Chatgpt;
    public static bool IsShared(this Agent value) => value == Agent.Antigravity;
    public static Uri Url(this Agent value) => new(value switch { Agent.Chatgpt => "https://chatgpt.com/", Agent.Claude => "https://claude.ai/", Agent.Gemini => "https://gemini.google.com/app", Agent.Perplexity => "https://www.perplexity.ai/", Agent.Deepseek => "https://chat.deepseek.com/", _ => "https://antigravity.google/" });
}
public sealed record Account {
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string EmailHint { get; set; } = "";
    public Agent Agent { get; init; }
    public Browser Browser { get; init; }
    public LaunchMode LaunchMode { get; set; } = LaunchMode.Desktop;
    public string Color { get; set; } = "mint";
    public bool IsFavorite { get; set; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? LastOpenedAt { get; set; }
    public DefaultAction DefaultAction { get; set; }
    public bool ConnectOnStartup { get; set; }
    public bool SharesLocalWorkspace { get; set; }
    public Connection? DesktopConnection { get; set; }
    public Connection? BrowserConnection { get; set; }
    [JsonIgnore] public LaunchMode EffectiveMode => Agent is Agent.Chatgpt or Agent.Claude ? LaunchMode : Agent.IsShared() ? LaunchMode.Desktop : LaunchMode.Browser;
    [JsonIgnore] public bool UsesCodexDesktop => Agent.HasQuota() && EffectiveMode == LaunchMode.Desktop;
    [JsonIgnore] public Connection? Connection => !Agent.HasQuota() ? null : UsesCodexDesktop ? DesktopConnection : BrowserConnection;
    public void Validate() {
        if (Id == Guid.Empty || Name.Trim().Length is < 1 or > 48 || EmailHint.Length > 160 || !ProfileColors.Names.Contains(Color) || !Enum.IsDefined(Agent) || !Enum.IsDefined(Browser) || !Enum.IsDefined(LaunchMode)) throw new AppError("Invalid profile data.");
    }
}
public sealed record Snapshot {
    public int Version { get; init; } = 1;
    public List<Account> Accounts { get; init; } = [];
    public Guid? LastOpenedId { get; set; }
    public void Validate() {
        if (Version != 1 || Accounts.Select(x => x.Id).Distinct().Count() != Accounts.Count || (LastOpenedId.HasValue && Accounts.All(x => x.Id != LastOpenedId))) throw new AppError("Could not read data. The existing file has been preserved.");
        foreach (var account in Accounts) account.Validate();
        if (Accounts.Count(x => x.Agent.IsShared()) > 1) throw new AppError("Antigravity uses one shared application sign-in. Edit the existing Antigravity entry instead.");
    }
}
public sealed record Preferences {
    public string Language { get; set; } = "vi";
    public string Theme { get; set; } = "light";
    public bool QuotaOnlyMode { get; set; }
    public WorkspaceLayout WorkspaceLayout { get; set; }
    public SortKey QuotaSortKey { get; set; }
    public bool QuotaSortAscending { get; set; } = true;
    public Agent? AgentFilter { get; set; }
    public bool AlertsEnabled { get; set; }
    public int AlertThreshold { get; set; } = 20;
    public bool AlertRecovery { get; set; } = true;
    public Dictionary<string, bool> AlertObservations { get; set; } = [];
    public Dictionary<string, string> Executables { get; set; } = [];
    public void SetQuotaOnly(bool enabled) { QuotaOnlyMode = enabled; WorkspaceLayout = enabled ? WorkspaceLayout.QuotaTable : WorkspaceLayout.Cards; }
    public void Normalize() {
        if (Language is not ("en" or "vi")) Language = "vi";
        if (!Themes.All.Any(x => x.Id == Theme)) Theme = "light";
        if (!Enum.IsDefined(WorkspaceLayout)) WorkspaceLayout = WorkspaceLayout.Cards;
        if (!Enum.IsDefined(QuotaSortKey)) QuotaSortKey = SortKey.Name;
        if (AgentFilter.HasValue && !Enum.IsDefined(AgentFilter.Value)) AgentFilter = null;
        AlertThreshold = Math.Clamp(AlertThreshold, 1, 95);
    }
}
public sealed record Theme(string Id, string Name, bool Dark, bool Mono, bool Retro, string Canvas, string Surface, string Sidebar, string Ink, string Secondary, string Accent, string OnAccent, string Line);
public static class Themes {
    public static readonly IReadOnlyList<Theme> All = Assets.Read<List<Theme>>("themes.json");
    public static Theme Get(string id) => All.FirstOrDefault(x => x.Id == id) ?? All[0];
}
public static class Assets {
    public static T Read<T>(string name) { using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("AISwitcher.Core.Assets." + name) ?? throw new InvalidOperationException(name); return JsonSerializer.Deserialize<T>(stream, Json.Options)!; }
}
public sealed class Localizer {
    readonly Dictionary<string, string> catalog;
    public string Language { get; }
    public CultureInfo Culture => CultureInfo.GetCultureInfo(Language == "vi" ? "vi-VN" : "en-US");
    public Localizer(string language) { Language = language == "en" ? "en" : "vi"; catalog = Assets.Read<Dictionary<string,string>>(Language + ".json"); }
    public string this[string key] => catalog.GetValueOrDefault(key, key);
    public string Format(string key, params object[] args) { var index = 0; return Regex.Replace(this[key], "%@|%%", m => m.Value == "%%" ? "%" : Convert.ToString(args[index++], Culture) ?? ""); }
    public string Date(DateTimeOffset date) => date.ToLocalTime().ToString("g", Culture);
}
public static class ProfileColors {
    public static readonly string[] Names = ["mint", "blue", "violet", "peach", "rose", "gold"];
    public static string Pale(string name, Theme theme) => theme.Retro ? name switch { "blue"=>"#A8D8F0", "violet"=>"#D5C0F4", "peach"=>"#FFB39E", "rose"=>"#FFA6C9", "gold"=>"#FFD84D", _=>"#B4EDC5" } : theme.Surface;
}
public sealed class AppError(string key) : Exception(key) { public string Key { get; } = key; }
