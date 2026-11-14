using System.Text.Json;
using System.Text;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace AISwitcher.Core;

public static class ClaudeDesktopAccount {
    public const string SignedOut = "Sign in to this account's Claude Desktop window, then refresh quota.";
    public const string Unavailable = "Claude did not return numeric usage limits for this account. Email and plan are still shown when available.";
    public const string Encryption = "This Claude Desktop session uses unsupported encryption. Its sign-in has been preserved.";
    public static (Identity Identity,string? Organization) Parse(JsonElement accountResponse, JsonElement organizations, string? selectedOrganization, string emailHint) {
        var account=ProviderQuota.Get(accountResponse,"account");if(account.ValueKind!=JsonValueKind.Object)account=accountResponse;
        var email=ProviderQuota.Get(account,"email_address");var id=ProviderQuota.Get(account,"uuid");
        if(email.ValueKind!=JsonValueKind.String||!email.GetString()!.Contains('@')||email.GetString()!.Length>320||id.ValueKind!=JsonValueKind.String||!Guid.TryParse(id.GetString(),out _))throw new AppError(ProviderQuota.Invalid);
        if(emailHint.Contains('@')&&!string.Equals(emailHint,email.GetString(),StringComparison.OrdinalIgnoreCase))throw new AppError(ProviderQuota.Changed);
        if(organizations.ValueKind!=JsonValueKind.Array)organizations=ProviderQuota.Get(organizations,"organizations");
        var rows=organizations.ValueKind==JsonValueKind.Array?organizations.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.Object).Take(20).ToArray():[];
        JsonElement? org=selectedOrganization!=null?rows.FirstOrDefault(x=>string.Equals(Text(x,"uuid"),selectedOrganization,StringComparison.OrdinalIgnoreCase)):null;
        if(org?.ValueKind!=JsonValueKind.Object)org=rows.Length==1?rows[0]:null;
        var plan=org.HasValue?Plan(org.Value):null;
        plan??=Named(Text(account,"subscription_type"));
        var orgId=org.HasValue?Text(org.Value,"uuid"):null;
        return(new(email.GetString(),plan,id.GetString()),Guid.TryParse(orgId,out _)?orgId:null);
    }
    static string? Text(JsonElement root,string key){var value=ProviderQuota.Get(root,key);return value.ValueKind==JsonValueKind.String?value.GetString():null;}
    static string? Named(string? value){value=value?.Trim().ToLowerInvariant();foreach(var plan in new[]{"free","pro","max","team","enterprise"})if(value==plan||value=="claude "+plan)return plan;return null;}
    static string? Plan(JsonElement org){
        var explicitPlan=Named(Text(org,"plan_display_name"))??Named(Text(org,"subscription_type"));if(explicitPlan!=null)return explicitPlan;
        var capabilities=ProviderQuota.Get(org,"capabilities");var flags=capabilities.ValueKind==JsonValueKind.Array?capabilities.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.String).Select(x=>x.GetString()!).ToArray():[];
        var raven=Named(Text(org,"raven_type"));if(raven is "team" or "enterprise")return raven;
        foreach(var plan in new[]{"enterprise","team","max","pro"})if(flags.Contains("claude_"+plan))return plan;
        if(!string.IsNullOrEmpty(Text(org,"raven_type")))return raven;
        if(Text(org,"billing_type")=="free"||ProviderQuota.Get(org,"billing_type").ValueKind==JsonValueKind.Null&&flags.Contains("chat")&&!flags.Any(flag=>new[]{"pro","max","team","enterprise"}.Any(plan=>flag.Contains(plan,StringComparison.OrdinalIgnoreCase))))return "free";
        return null;
    }
    public static string DecryptCookie(byte[] encrypted,byte[] key,string host,bool requiresHostDigest) {
        if(key.Length is not (16 or 24 or 32))throw new AppError(Encryption);
        if(encrypted.Length<31||!encrypted.AsSpan(0,3).SequenceEqual("v10"u8))throw new AppError(Encryption);
        var plain=new byte[encrypted.Length-31];
        try {
            using var aes=new AesGcm(key,16);
            aes.Decrypt(encrypted.AsSpan(3,12),encrypted.AsSpan(15,plain.Length),encrypted.AsSpan(encrypted.Length-16),plain);
            return CookieText(plain,host,requiresHostDigest);
        } catch(CryptographicException) { throw new AppError(Encryption); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public static string CookieText(byte[] plain,string host,bool requiresHostDigest) {
        var digest=SHA256.HashData(Encoding.UTF8.GetBytes(host));
        var start=plain.Length>=32&&CryptographicOperations.FixedTimeEquals(plain.AsSpan(0,32),digest)?32:0;
        if(requiresHostDigest&&start==0)throw new AppError(Encryption);
        try { return new UTF8Encoding(false,true).GetString(plain.AsSpan(start)); }
        catch(DecoderFallbackException) { throw new AppError(Encryption); }
    }
    public static Connection Usage(JsonElement raw,Identity identity){
        var limits=ProviderQuota.Get(raw,"rate_limits");if(limits.ValueKind!=JsonValueKind.Object)limits=raw;
        if(limits.ValueKind!=JsonValueKind.Object)throw new AppError(ProviderQuota.Invalid);
        var allowed=new[]{"five_hour","seven_day","seven_day_opus","seven_day_sonnet","seven_day_oauth_apps","model_scoped"};
        var clean=new JsonObject();foreach(var property in limits.EnumerateObject())if(allowed.Contains(property.Name))clean[property.Name]=JsonNode.Parse(property.Value.GetRawText());
        if(clean.Count==0||ProviderQuota.Get(raw,"rate_limits_available").ValueKind==JsonValueKind.False){if(string.IsNullOrWhiteSpace(identity.Email))throw new AppError(ProviderQuota.Unavailable);return new(identity,null,DateTimeOffset.UtcNow,"claudeDesktop");}
        using var doc=JsonDocument.Parse(new JsonObject{["rate_limits_available"]=true,["rate_limits"]=clean}.ToJsonString());
        return ProviderQuota.Parse(doc.RootElement,Agent.Claude,identity);
    }
}
