using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static class SharedWorkspace {
    public static string Source(Preferences prefs)=>prefs.Executables.GetValueOrDefault("workspace")??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".codex");
    public static bool BindingMatches(Account account,Repository repo,Preferences prefs){
        var marker=Path.Combine(repo.QuotaHome(account),"ai-switcher-workspace.json");Repository.RejectLinks(marker);
        if(!account.SharesLocalWorkspace)return !File.Exists(marker);
        if(!File.Exists(marker))return false;var data=JsonNode.Parse(File.ReadAllText(marker))!.AsObject();
        static bool Matches(string? left,string? right)=>string.IsNullOrWhiteSpace(left)||string.IsNullOrWhiteSpace(right)?string.IsNullOrWhiteSpace(left)&&string.IsNullOrWhiteSpace(right):NativePlatform.SamePath(left,right);
        return Matches(data["source"]?.GetValue<string>(),Source(prefs))&&Matches(data["database"]?.GetValue<string>(),Database(prefs))&&Matches(data["artifacts"]?.GetValue<string>(),prefs.Executables.GetValueOrDefault("artifacts"));
    }
    public static string BoundDatabase(Account account,Repository repo,Preferences prefs){var marker=Path.Combine(repo.QuotaHome(account),"ai-switcher-workspace.json");Repository.RejectLinks(marker);return File.Exists(marker)?JsonNode.Parse(File.ReadAllText(marker))!["database"]!.GetValue<string>():Database(prefs);}
    public static string Database(Preferences prefs){
        if(prefs.Executables.TryGetValue("database",out var configured)&&!string.IsNullOrWhiteSpace(configured))return Path.GetFullPath(configured);
        var source=Source(prefs);var config=Path.Combine(source,"config.toml");Repository.RejectLinks(config);
        if(File.Exists(config))foreach(var line in File.ReadLines(config)){
            var text=line.Trim();if(text.StartsWith("[",StringComparison.Ordinal))break;
            var match=System.Text.RegularExpressions.Regex.Match(text,"""^sqlite_home\s*=\s*("(?:\\.|[^"\\])*"|'[^']*')\s*(?:#.*)?$""");
            if(text.StartsWith("sqlite_home",StringComparison.Ordinal)&&!match.Success)throw new AppError("The local workspace paths could not be verified.");
            if(match.Success){var value=match.Groups[1].Value.Trim();string path;
                if(value.StartsWith('\"'))path=JsonSerializer.Deserialize<string>(value)??throw new AppError("The local workspace paths could not be verified.");
                else if(value.StartsWith('\''))path=value.Trim('\'');else throw new AppError("The local workspace paths could not be verified.");
                if(path.StartsWith("~/",StringComparison.Ordinal)||path.StartsWith("~\\",StringComparison.Ordinal))path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),path[2..]);
                return Path.GetFullPath(path,source);
            }
        }
        return source;
    }
    static readonly string[] Keys=["local-projects","project-order","project-appearances","pinned-project-ids","projectless-thread-ids","thread-projectless-output-directories","thread-workspace-root-hints","thread-project-assignments","thread-project-membership-host-ids","thread-writable-roots","pinned-thread-ids","sidebar-project-thread-orders","electron-managed-worktree-archives","app-server-project-id-by-legacy-project-id-by-host","app-server-projects-migration-by-host"];
    public static async Task PrepareAsync(Account account,Repository repo,Preferences prefs){
        var home=repo.QuotaHome(account);var marker=Path.Combine(home,"ai-switcher-workspace.json");Repository.RejectLinks(marker);
        if(!account.SharesLocalWorkspace){Restore(home,marker);return;}
        var source=Path.GetFullPath(Source(prefs));Repository.RejectLinks(source);var database=Database(prefs);Repository.RejectLinks(database);if(!Directory.Exists(database))throw new AppError("The local workspace paths could not be verified.");
        if(Within(database,repo.Root)||Within(database,repo.BackendBase))throw new AppError("The local workspace paths could not be verified.");
        if(!Directory.Exists(source)||Within(source,repo.Root)||Within(source,repo.BackendBase))throw new AppError("The local workspace paths could not be verified. No existing workspace data was replaced.");
        var dirs=new[]{"sessions","archived_sessions"};
        var previous=File.Exists(marker)?JsonNode.Parse(File.ReadAllText(marker))!.AsObject():null;
        if(previous!=null&&(previous["source"]?.GetValue<string>()!=source||previous["database"]?.GetValue<string>()!=database||(previous["artifacts"]!=null&&previous["artifacts"]?.GetValue<string>()!=prefs.Executables.GetValueOrDefault("artifacts"))))throw new AppError("Close this profile and disable workspace sharing before choosing another workspace.");
        if(previous==null){
            foreach(var name in dirs){var path=Path.Combine(home,name);Repository.RejectLinks(path);if(Directory.Exists(path)&&Directory.EnumerateFileSystemEntries(path).Any())throw new AppError("This profile already has private local history. Use a new profile to share an existing workspace.");}
            if(WorkspaceIndex.ContainsHistory(home))throw new AppError("This profile already has private local history. Use a new profile to share an existing workspace.");
        }
        var statePath=Path.Combine(home,".codex-global-state.json");Repository.RejectLinks(statePath);
        var sourceState=Path.Combine(source,".codex-global-state.json");Repository.RejectLinks(sourceState);
        var state=File.Exists(statePath)?JsonNode.Parse(File.ReadAllText(statePath))!.AsObject():new JsonObject();
        var old=previous?["previous"]?.DeepClone()??new JsonObject(Keys.Where(state.ContainsKey).Select(k=>new KeyValuePair<string,JsonNode?>(k,state[k]?.DeepClone())));
        // Save a recovery marker before creating any links. Only workspace keys are retained.
        File.WriteAllText(marker,new JsonObject{["source"]=source,["database"]=database,["previous"]=old,["artifacts"]=previous?["artifacts"]?.DeepClone()}.ToJsonString());
        foreach(var name in dirs){var target=Path.Combine(source,name);Repository.RejectLinks(target);Directory.CreateDirectory(target);var link=Path.Combine(home,name);
            if(Directory.Exists(link)&&(File.GetAttributes(link)&FileAttributes.ReparsePoint)!=0){if(!NativePlatform.SamePath(new DirectoryInfo(link).ResolveLinkTarget(true)!.FullName,target))throw new AppError("The local workspace paths could not be verified.");continue;}
            if(Directory.Exists(link))Directory.Delete(link);await JunctionAsync(link,target);
        }
        var artifact=prefs.Executables.GetValueOrDefault("artifacts");
        if(!string.IsNullOrWhiteSpace(artifact)){
            artifact=Path.GetFullPath(artifact);Repository.RejectLinks(artifact);
            if(!Directory.Exists(artifact)||Within(artifact,repo.Root)||Within(artifact,repo.BackendBase))throw new AppError("The local workspace paths could not be verified.");
            // Record the destination before moving a private cache, so an interrupted
            // junction operation can still restore the original directory.
            var binding=JsonNode.Parse(File.ReadAllText(marker))!.AsObject();binding["artifacts"]=artifact;File.WriteAllText(marker,binding.ToJsonString());
            var link=Path.Combine(repo.DataPath(account),"artifact-sessions");
            if(Directory.Exists(link)&&(File.GetAttributes(link)&FileAttributes.ReparsePoint)!=0){if(!NativePlatform.SamePath(new DirectoryInfo(link).ResolveLinkTarget(true)!.FullName,artifact))throw new AppError("The local workspace paths could not be verified.");}
            else{
                var backup=Path.Combine(repo.ProfilePath(account),"WorkspaceBackup","artifact-sessions");
                if(Directory.Exists(link)){if(Directory.Exists(backup))throw new AppError("The local workspace paths could not be verified.");Repository.RejectLinks(Path.GetDirectoryName(backup)!);Directory.CreateDirectory(Path.GetDirectoryName(backup)!);Directory.Move(link,backup);}
                await JunctionAsync(link,artifact);
            }
        }
        foreach(var incoming in MetadataSources(account,repo,source))foreach(var key in Keys.Where(incoming.ContainsKey))state[key]=Merge(state[key],incoming[key]);
        var recovery=Path.Combine(repo.Root,"SharedWorkspaceAccountLinks");
        var originalState=state.ToJsonString();var detached=SharedLocalProjects.DetachState(state);
        if(detached.Count>0)WorkspaceIndex.SaveRecovery(recovery,home+"\n"+originalState,new JsonObject{["profileId"]=account.Id.ToString(),["entries"]=detached});
        WorkspaceIndex.DetachLocalProjectAccounts(database,recovery);
        File.WriteAllText(statePath,state.ToJsonString());
        RefreshRolloutPaths(account,repo,prefs);
    }
    public static void RefreshRolloutPaths(Account account,Repository repo,Preferences prefs){
        if(!account.UsesCodexDesktop||!account.SharesLocalWorkspace)return;
        var home=repo.QuotaHome(account);repo.ValidateOwned(home,account.Id);
        if(!BindingMatches(account,repo,prefs))throw new AppError("The local workspace paths could not be verified.");
        var source=Path.GetFullPath(Source(prefs));Repository.RejectLinks(source);
        foreach(var name in new[]{"sessions","archived_sessions"}){
            var link=Path.Combine(home,name);
            if(!Directory.Exists(link)||(File.GetAttributes(link)&FileAttributes.ReparsePoint)==0||!NativePlatform.SamePath(new DirectoryInfo(link).ResolveLinkTarget(true)!.FullName,Path.Combine(source,name)))throw new AppError("The local workspace paths could not be verified.");
        }
        WorkspaceIndex.ProjectToProfile(BoundDatabase(account,repo,prefs),source,home);
    }
    static JsonNode? Merge(JsonNode? current,JsonNode? incoming){
        if(current is JsonObject oldObject&&incoming is JsonObject newObject){var merged=oldObject.DeepClone().AsObject();foreach(var pair in newObject)merged[pair.Key]=Merge(merged[pair.Key],pair.Value);return merged;}
        if(current is JsonArray oldArray&&incoming is JsonArray newArray){var merged=oldArray.DeepClone().AsArray();var seen=merged.Select(x=>x?.ToJsonString()).ToHashSet();foreach(var item in newArray)if(seen.Add(item?.ToJsonString()))merged.Add(item?.DeepClone());return merged;}
        return incoming?.DeepClone();
    }
    static IEnumerable<JsonObject> MetadataSources(Account account,Repository repo,string source){
        var archives=Path.Combine(repo.Root,"SharedWorkspaceMetadata");Repository.RejectLinks(archives);
        if(Directory.Exists(archives))foreach(var file in Directory.EnumerateFiles(archives,"*.json")){Repository.RejectLinks(file);var archive=JsonNode.Parse(File.ReadAllText(file))!.AsObject();if(archive["source"]?.GetValue<string>()==source&&archive["metadata"] is JsonObject metadata)yield return metadata;}
        foreach(var other in repo.Load().Accounts.Where(x=>x.Id!=account.Id&&x.UsesCodexDesktop&&x.SharesLocalWorkspace)){
            repo.ValidateOwned(repo.QuotaHome(other),other.Id);var binding=Path.Combine(repo.QuotaHome(other),"ai-switcher-workspace.json");Repository.RejectLinks(binding);if(!File.Exists(binding)||JsonNode.Parse(File.ReadAllText(binding))!["source"]?.GetValue<string>()!=source)continue;var path=Path.Combine(repo.QuotaHome(other),".codex-global-state.json");Repository.RejectLinks(path);if(File.Exists(path))yield return JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        }
        var original=Path.Combine(source,".codex-global-state.json");Repository.RejectLinks(original);if(File.Exists(original))yield return JsonNode.Parse(File.ReadAllText(original))!.AsObject();
    }
    public static void Archive(Account account,Repository repo){
        var home=repo.QuotaHome(account);var marker=Path.Combine(home,"ai-switcher-workspace.json");Repository.RejectLinks(marker);if(!File.Exists(marker))return;
        repo.ValidateOwned(home,account.Id);var binding=JsonNode.Parse(File.ReadAllText(marker))!.AsObject();var source=binding["source"]!.GetValue<string>();var database=binding["database"]?.GetValue<string>()??source;
        WorkspaceIndex.Canonicalize(database,home,source);
        var statePath=Path.Combine(home,".codex-global-state.json");Repository.RejectLinks(statePath);if(!File.Exists(statePath))return;var state=JsonNode.Parse(File.ReadAllText(statePath))!.AsObject();
        var folder=Path.Combine(repo.Root,"SharedWorkspaceMetadata");Repository.RejectLinks(folder);Directory.CreateDirectory(folder);
        var metadata=new JsonObject(Keys.Where(state.ContainsKey).Select(key=>new KeyValuePair<string,JsonNode?>(key,state[key]?.DeepClone())));var target=Path.Combine(folder,account.Id+".json");Repository.RejectLinks(target);var temp=target+".tmp";Repository.RejectLinks(temp);File.WriteAllText(temp,new JsonObject{["source"]=source,["metadata"]=metadata}.ToJsonString());File.Move(temp,target,true);
    }

    static void Restore(string home,string marker){
        if(!File.Exists(marker))return;var data=JsonNode.Parse(File.ReadAllText(marker))!.AsObject();var source=data["source"]!.GetValue<string>();
        foreach(var name in new[]{"sessions","archived_sessions"}){var link=Path.Combine(home,name);if(!Directory.Exists(link))continue;if((File.GetAttributes(link)&FileAttributes.ReparsePoint)==0&&!Directory.EnumerateFileSystemEntries(link).Any())continue;if((File.GetAttributes(link)&FileAttributes.ReparsePoint)==0||!NativePlatform.SamePath(new DirectoryInfo(link).ResolveLinkTarget(true)!.FullName,Path.Combine(source,name)))throw new AppError("The local workspace paths could not be verified.");Directory.Delete(link);}
        if(data["artifacts"] is JsonValue artifactValue){var artifact=artifactValue.GetValue<string>();var profileId=JsonNode.Parse(File.ReadAllText(Path.Combine(home,"ai-switcher-profile.json")))!["id"]!.GetValue<string>();var root=JsonNode.Parse(File.ReadAllText(Path.Combine(home,"ai-switcher-profile.json")))!["root"]!.GetValue<string>();var link=Path.Combine(root,"Desktop",profileId,"UserData","artifact-sessions");
            if(Directory.Exists(link)&&(File.GetAttributes(link)&FileAttributes.ReparsePoint)!=0){if(!NativePlatform.SamePath(new DirectoryInfo(link).ResolveLinkTarget(true)!.FullName,artifact))throw new AppError("The local workspace paths could not be verified.");Directory.Delete(link);}
            var backup=Path.Combine(root,"Desktop",profileId,"WorkspaceBackup","artifact-sessions");Repository.RejectLinks(Path.GetDirectoryName(backup)!);Repository.RejectLinks(backup);if(Directory.Exists(backup))Directory.Move(backup,link);
        }
        var path=Path.Combine(home,".codex-global-state.json");Repository.RejectLinks(path);var state=File.Exists(path)?JsonNode.Parse(File.ReadAllText(path))!.AsObject():new JsonObject();var old=data["previous"]!.AsObject();foreach(var key in Keys){if(old.ContainsKey(key))state[key]=old[key]?.DeepClone();else state.Remove(key);}File.WriteAllText(path,state.ToJsonString());File.Delete(marker);
    }
    static bool Within(string path,string parent)=>NativePlatform.SamePath(path,parent)||path.StartsWith(parent.TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase);
    static async Task JunctionAsync(string link,string target){
        var info=new ProcessStartInfo("powershell.exe"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
        foreach(var arg in new[]{"-NoProfile","-NonInteractive","-Command","New-Item -ItemType Junction -Path $env:AISW_LINK -Target $env:AISW_TARGET -ErrorAction Stop | Out-Null"})info.ArgumentList.Add(arg);info.Environment["AISW_LINK"]=link;info.Environment["AISW_TARGET"]=target;
        using var process=Process.Start(info)??throw new AppError("The local workspace paths could not be verified.");var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));await output;await error;if(process.ExitCode!=0)throw new AppError("The local workspace paths could not be verified.");
    }
}
