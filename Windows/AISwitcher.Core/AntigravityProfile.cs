using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AISwitcher.Core;
public static class AntigravityProfile {
    public const string DesktopSessionKind="antigravityWindowsDesktopV1",CliSessionKind="antigravityWindowsCliV1";
    public const string MarkerArgument="--ai-switcher-antigravity-private-storage=v1";
    public const string Unsupported="This Antigravity version could not be verified for separate profiles. Update Antigravity and try again.";
    public static string Home(Repository repo,Account account)=>Path.Combine(repo.ProfilePath(account),"Home");
    public static string DesktopIdentity(Repository repo,Account account)=>Path.Combine(Home(repo,account),".gemini","jetski-standalone-oauth-token");
    public static string CliIdentity(Repository repo,Account account)=>Path.Combine(Home(repo,account),".gemini","antigravity-cli","antigravity-oauth-token");
    public static IEnumerable<string> Directories(Repository repo,Account account)=>new[]{Home(repo,account),Path.Combine(Home(repo,account),".gemini"),Path.Combine(Home(repo,account),".gemini","antigravity-cli"),Path.Combine(Home(repo,account),"AppData","Roaming"),Path.Combine(Home(repo,account),"AppData","Local")};
    public static void Validate(Repository repo,Account account){
        if(!account.UsesPrivateAntigravity)throw new AppError(Unsupported);
        repo.ValidateOwned(repo.ProfilePath(account),account.Id);Repository.RejectLinks(Path.Combine(repo.Root,"Antigravity"));Repository.RejectLinks(repo.DataPath(account));
        foreach(var path in Directories(repo,account)){
            var current=path;while(current.Length>=repo.ProfilePath(account).Length){Repository.RejectLinks(current);if(current==repo.ProfilePath(account))break;current=Path.GetDirectoryName(current)!;}
        }
        foreach(var path in new[]{DesktopIdentity(repo,account),CliIdentity(repo,account)})Repository.RejectLinks(path);
    }
    public static Dictionary<string,string> Environment(IReadOnlyDictionary<string,string> inherited,Repository repo,Account account){
        var env=ChildEnvironment.Create(inherited);var home=Home(repo,account);
        env["HOME"]=home;env["USERPROFILE"]=home;env["HOMEDRIVE"]=Path.GetPathRoot(home)!.TrimEnd(Path.DirectorySeparatorChar);env["HOMEPATH"]=home[env["HOMEDRIVE"].Length..];
        env["APPDATA"]=Path.Combine(home,"AppData","Roaming");env["LOCALAPPDATA"]=Path.Combine(home,"AppData","Local");
        env["XDG_CONFIG_HOME"]=Path.Combine(home,".config");env["XDG_CACHE_HOME"]=Path.Combine(home,".cache");env["XDG_DATA_HOME"]=Path.Combine(home,".local","share");
        // The vendor's native keyring adapter detects WSL_INTEROP and opts into
        // its file store. This is a storage compatibility flag, not an OS sandbox.
        // No SSH/headless flags: browser OAuth must retain its localhost callback.
        // Native vendor integration tests verify this branch on each release.
        env["WSL_INTEROP"]="AI-Switcher-private-file-storage";
        env["AGY_CLI_DISABLE_AUTO_UPDATE"]="true";
        return env;
    }
    public static bool SupportsPrivateStorage(string executable){
        if(!File.Exists(executable))return false;
        var bytes=File.ReadAllBytes(executable);
        return new[]{"WSL_INTEROP","Using file-based token storage because %s detected",".gemini"}.All(term=>bytes.AsSpan().IndexOf(Encoding.ASCII.GetBytes(term))>=0);
    }
    public static bool ValidEmail(string? email)=>email is {Length:>3 and <=320}&&Regex.IsMatch(email,@"^[^\s@]+@[^\s@]+\.[^\s@]+$");
    public static Identity? ReadIdentity(string path){
        Repository.RejectLinks(path);if(!File.Exists(path))return null;
        using var file=File.OpenRead(path);if(file.Length>131072)throw new AppError(ProviderQuota.Invalid);
        try{
            using var doc=JsonDocument.Parse(file);var root=doc.RootElement;
            if(ProviderQuota.Get(root,"auth_method").GetString()!="consumer")return null;
            if(ProviderQuota.Get(root,"id_token_email") is {ValueKind:JsonValueKind.String} value&&ValidEmail(value.GetString()))return new(value.GetString(),null);
            if(ProviderQuota.Get(root,"id_token") is not {ValueKind:JsonValueKind.String} token)return null;
            var parts=token.GetString()!.Split('.');if(parts.Length!=3||parts[2].Length==0)return null;
            static JsonElement Decode(string part){var b64=part.Replace('-','+').Replace('_','/');using var json=JsonDocument.Parse(Convert.FromBase64String(b64.PadRight((b64.Length+3)/4*4,'=')));return json.RootElement.Clone();}
            var header=Decode(parts[0]);var claims=Decode(parts[1]);
            var email=ProviderQuota.Get(claims,"email");var issuer=ProviderQuota.Get(claims,"iss");
            return ProviderQuota.Get(header,"alg").GetString()=="RS256"&&issuer.GetString() is "accounts.google.com" or "https://accounts.google.com"&&ProviderQuota.Get(claims,"email_verified").ValueKind==JsonValueKind.True&&ValidEmail(email.GetString())?new(email.GetString(),null):null;
        }catch(Exception error)when(error is JsonException or FormatException or InvalidOperationException){return null;}
    }
    public static string DisplayTitle(string id,string? name,string? group=null){
        var text=(id+" "+name+" "+group).ToLowerInvariant();
        return text.Contains("gemini")?"Gemini models":text.Contains("claude")||text.Contains("gpt")||text.Contains("3p")?"Claude and GPT models":group??name??id;
    }
    public static Identity Status(JsonElement root){
        var status=ProviderQuota.Get(root,"userStatus");var email=ProviderQuota.Get(status,"email");
        if(email.ValueKind!=JsonValueKind.String||!ValidEmail(email.GetString()))throw new AppError(ProviderQuota.SignedOut);
        var plan=ProviderQuota.Get(ProviderQuota.Get(ProviderQuota.Get(status,"planStatus"),"planInfo"),"planName");
        return new(email.GetString(),plan.ValueKind==JsonValueKind.String&&!string.IsNullOrWhiteSpace(plan.GetString())?plan.GetString():null);
    }
    public static Connection Parse(JsonElement before,JsonElement quota,JsonElement after,string hint="",DateTimeOffset? time=null){
        var identity=Status(before);if(identity!=Status(after)||hint.Contains('@')&&!string.Equals(hint,identity.Email,StringComparison.OrdinalIgnoreCase))throw new AppError(ProviderQuota.Changed);
        var groups=ProviderQuota.Get(ProviderQuota.Get(quota,"response"),"groups");if(groups.ValueKind!=JsonValueKind.Array)throw new AppError(ProviderQuota.Invalid);
        var now=time??DateTimeOffset.UtcNow;
        if(groups.GetArrayLength()==0)return new(identity,null,now,DesktopSessionKind);
        var normalized=new JsonArray();
        foreach(var group in groups.EnumerateArray()){
            var target=new JsonObject{["name"]=JsonNode.Parse(ProviderQuota.Get(group,"displayName").ValueKind==JsonValueKind.Undefined?"null":ProviderQuota.Get(group,"displayName").GetRawText()),["buckets"]=new JsonArray()};
            var buckets=ProviderQuota.Get(group,"buckets");if(buckets.ValueKind!=JsonValueKind.Array)throw new AppError(ProviderQuota.Invalid);
            foreach(var bucket in buckets.EnumerateArray()){
                var value=new JsonObject();foreach(var (native,common) in new[]{("bucketId","id"),("displayName","name"),("window","window"),("remainingFraction","remaining_fraction"),("resetTime","reset_time")})if(ProviderQuota.Get(bucket,native) is {ValueKind:not JsonValueKind.Undefined} field)value[common]=JsonNode.Parse(field.GetRawText());
                target["buckets"]!.AsArray().Add(value);
            }
            normalized.Add(target);
        }
        using var envelope=JsonDocument.Parse(new JsonObject{["num_turns"]=0,["command"]=new JsonObject{["name"]="usage",["data"]=new JsonObject{["groups"]=normalized}}}.ToJsonString());
        return ProviderQuota.Parse(envelope.RootElement,Agent.Antigravity,identity,now)with{IdentityFetchedAt=now,ProviderSessionKind=DesktopSessionKind};
    }
}
