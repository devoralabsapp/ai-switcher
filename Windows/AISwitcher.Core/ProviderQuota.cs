using System.Text.Json;
using System.Text.RegularExpressions;

namespace AISwitcher.Core;
public static class ProviderQuota {
    public static readonly string[] ClaudeArguments=["-p","--input-format","stream-json","--output-format","stream-json","--verbose","--safe-mode","--no-session-persistence","--settings","{\"disableAllHooks\":true}","--mcp-config","{\"mcpServers\":{}}","--strict-mcp-config"];
    public static readonly string[] AntigravityArguments=["-p","/usage","--output-format","json"];
    public static bool Accepts(string version,Agent agent){
        if(agent==Agent.Claude&&!version.Contains("claude",StringComparison.OrdinalIgnoreCase))return false;
        if(agent==Agent.Antigravity&&!version.Contains("antigravity",StringComparison.OrdinalIgnoreCase)&&!version.Contains("agy",StringComparison.OrdinalIgnoreCase)&&!Regex.IsMatch(version.Trim(),@"^\d+\.\d+\.\d+$"))return false;
        var match=Regex.Match(version,@"(?:^|\s)(\d+)\.(\d+)\.(\d+)(?:\s|$|[-+])");if(!match.Success)return false;
        return Version.TryParse($"{match.Groups[1]}.{match.Groups[2]}.{match.Groups[3]}",out var value)&&value >= (agent==Agent.Claude?new Version(2,1,270):new Version(1,1,12));
    }
    public static string ControlRequest(string id,string subtype){
        if(subtype is not ("initialize" or "get_usage"))throw new AppError(Invalid);
        Dictionary<string,object> request=new(){{"subtype",subtype}};if(subtype=="get_usage")request["skip_behaviors"]=true;
        // JSONL must stay compact on Windows too; stripping LF from pretty CRLF JSON leaves record separators.
        return JsonSerializer.Serialize(new{type="control_request",request_id=id,request});
    }
    public const string Unavailable="The provider has not returned subscription quota. Previous data is kept.";
    public const string Invalid="The provider quota response could not be verified. Previous data is kept.";
    public const string SignedOut="The provider session is signed out. Choose Sign in with official CLI, then connect again.";
    public const string Changed="The provider account does not match this profile. Verify the email before reconnecting.";
    public const string Outdated="Update the provider CLI to read quota without starting a model turn.";
    public static JsonElement Get(JsonElement parent,string key)=>parent.ValueKind==JsonValueKind.Object&&parent.TryGetProperty(key,out var value)?value:default;
    static double? Number(JsonElement value)=>value.ValueKind==JsonValueKind.Number&&value.TryGetDouble(out var d)&&double.IsFinite(d)?d:null;
    static string? String(JsonElement value)=>value.ValueKind==JsonValueKind.String?value.GetString():null;
    public static Connection Parse(JsonElement root,Agent agent,Identity identity,DateTimeOffset? fetched=null){
        var now=fetched??DateTimeOffset.UtcNow;var payload=Get(root,"data");if(payload.ValueKind!=JsonValueKind.Object)payload=root;
        var buckets=new Dictionary<string,Bucket>();
        QuotaWindow? Window(JsonElement raw,int? minutes,bool fraction=false){
            var n=Number(Get(raw,fraction?"remaining_fraction":"utilization"))??(fraction?null:Number(Get(raw,"used_percentage")));double? used=n>=0&&n<=(fraction?1:100)?fraction?100*(1-n):n:null;
            var amount=fraction?Number(Get(raw,"remaining_amount")):null;if(amount<0)amount=null;
            if(used==null&&amount==null)return null;
            var reset=Get(raw,"resets_at");if(reset.ValueKind==JsonValueKind.Undefined)reset=Get(raw,"reset_time");long? at=null;
            if(Number(reset) is double epoch&&epoch>0&&epoch<253402300800)at=(long)epoch;
            else if(DateTimeOffset.TryParse(String(reset),System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AssumeUniversal,out var date))at=date.ToUnixTimeSeconds();
            else if(Number(Get(raw,"reset_in_seconds")) is double seconds&&seconds>=0&&seconds<31536000)at=now.ToUnixTimeSeconds()+(long)seconds;
            return new(used,minutes,at,amount);
        }
        if(agent==Agent.Claude){
            var limits=Get(payload,"rate_limits");if(Get(payload,"rate_limits_available").ValueKind==JsonValueKind.False||limits.ValueKind!=JsonValueKind.Object)throw new AppError(Unavailable);
            var primary=Window(Get(limits,"five_hour"),300);var secondary=Window(Get(limits,"seven_day"),10080);
            if(primary!=null||secondary!=null)buckets["claude"]=new("claude","Claude",primary,secondary);
            foreach(var item in limits.EnumerateObject()){
                if(new[]{"five_hour","seven_day","extra_usage","model_scoped"}.Contains(item.Name))continue;
                if(Window(item.Value,item.Name.StartsWith("seven_day",StringComparison.Ordinal)?10080:null) is {} w)buckets[item.Name]=new(item.Name,item.Name.Replace('_',' '),w,null);
            }
            var models=Get(limits,"model_scoped");if(models.ValueKind==JsonValueKind.Array){int i=0;foreach(var raw in models.EnumerateArray())if(Window(raw,null) is {} w){var id="claude-model-"+i++;buckets[id]=new(id,String(Get(raw,"display_name"))??id,w,null);}}
        }else if(agent==Agent.Antigravity){
            List<(string Id,JsonElement Raw)> rows=[];var command=Get(root,"command");
            if(command.ValueKind==JsonValueKind.Object){
                if(String(Get(command,"name"))!="usage"||(Number(Get(root,"num_turns"))??0)!=0)throw new AppError(Invalid);
                var groups=Get(Get(command,"data"),"groups");if(groups.ValueKind!=JsonValueKind.Array)throw new AppError(Invalid);
                foreach(var group in groups.EnumerateArray()){var list=Get(group,"buckets");if(list.ValueKind!=JsonValueKind.Array)continue;foreach(var raw in list.EnumerateArray())if(String(Get(raw,"id")) is {} id)rows.Add((id,raw));}
            }else{var quota=Get(payload,"quota");if(quota.ValueKind!=JsonValueKind.Object)throw new AppError(Unavailable);foreach(var pair in quota.EnumerateObject())rows.Add((pair.Name,pair.Value));}
            foreach(var (id,raw) in rows){
                if(id.Length>160||Get(raw,"disabled").ValueKind==JsonValueKind.True)continue;
                var label=String(Get(raw,"window"))??id;int? mins=label.Contains("week",StringComparison.OrdinalIgnoreCase)||label=="7d"?10080:new[]{"5h","5 hours","five_hour"}.Contains(label.ToLowerInvariant())?300:null;
                if(Window(raw,mins,true) is {} w){if(!buckets.TryAdd(id,new(id,String(Get(raw,"name"))??id.Replace('-',' '),w,null)))throw new AppError(Invalid);}
            }
        }else throw new AppError(Invalid);
        if(buckets.Count==0)throw new AppError(Unavailable);
        return new(identity,new(new(null,null,buckets),now));
    }
}
