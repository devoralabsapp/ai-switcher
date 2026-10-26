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
    static readonly string[] Keys=["local-projects","project-order","project-appearances","pinned-project-ids","projectless-thread-ids","thread-projectless-output-directories","thread-workspace-root-hints","thread-project-assignments","thread-project-membership-host-ids","thread-writable-roots","pinned-thread-ids","sidebar-project-thread-orders","electron-managed-worktree-archives","app-server-project-id-by-legacy-project-id-by-host","app-server-projects-migration-by-host"];
    public static async Task PrepareAsync(Account account,Repository repo,Preferences prefs){
        var home=repo.QuotaHome(account);var marker=Path.Combine(home,"ai-switcher-workspace.json");Repository.RejectLinks(marker);
        if(!account.SharesLocalWorkspace){Restore(home,marker);return;}
        var source=Path.GetFullPath(Source(prefs));Repository.RejectLinks(source);
        if(!Directory.Exists(source)||source.StartsWith(repo.Root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)||source.StartsWith(repo.BackendBase+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new AppError("The local workspace paths could not be verified. No existing workspace data was replaced.");
        var dirs=new[]{"sessions","archived_sessions"};
        var previous=File.Exists(marker)?JsonNode.Parse(File.ReadAllText(marker))!.AsObject():null;
        if(previous!=null&&previous["source"]?.GetValue<string>()!=source)throw new AppError("Close this profile and disable workspace sharing before choosing another workspace.");
        if(previous==null){
            foreach(var name in dirs){var path=Path.Combine(home,name);Repository.RejectLinks(path);if(Directory.Exists(path)&&Directory.EnumerateFileSystemEntries(path).Any())throw new AppError("This profile already has private local history. Use a new profile to share an existing workspace.");}
            if(Directory.EnumerateFiles(home,"*.sqlite*").Any(x=>new FileInfo(x).Length>0))throw new AppError("This profile already has private local history. Use a new profile to share an existing workspace.");
        }
        var statePath=Path.Combine(home,".codex-global-state.json");Repository.RejectLinks(statePath);
        var sourceState=Path.Combine(source,".codex-global-state.json");Repository.RejectLinks(sourceState);
        var state=File.Exists(statePath)?JsonNode.Parse(File.ReadAllText(statePath))!.AsObject():new JsonObject();
        var old=previous?["previous"]?.DeepClone()??new JsonObject(Keys.Where(state.ContainsKey).Select(k=>new KeyValuePair<string,JsonNode?>(k,state[k]?.DeepClone())));
        // Save a recovery marker before creating any links. Only workspace keys are retained.
        File.WriteAllText(marker,new JsonObject{["source"]=source,["previous"]=old}.ToJsonString());
        foreach(var name in dirs){var target=Path.Combine(source,name);Repository.RejectLinks(target);Directory.CreateDirectory(target);var link=Path.Combine(home,name);
            if(Directory.Exists(link)&&(File.GetAttributes(link)&FileAttributes.ReparsePoint)!=0){if(!NativePlatform.SamePath(new DirectoryInfo(link).ResolveLinkTarget(true)!.FullName,target))throw new AppError("The local workspace paths could not be verified.");continue;}
            if(Directory.Exists(link))Directory.Delete(link);await JunctionAsync(link,target);
        }
        if(File.Exists(sourceState)){
            var original=JsonNode.Parse(File.ReadAllText(sourceState))!.AsObject();
            foreach(var key in Keys.Where(original.ContainsKey)){
                if(original[key] is JsonArray incoming){var merged=(state[key] as JsonArray)?.DeepClone().AsArray()??new JsonArray();var seen=merged.Select(x=>x?.ToJsonString()).ToHashSet();foreach(var item in incoming)if(seen.Add(item?.ToJsonString()))merged.Add(item?.DeepClone());state[key]=merged;}
                else if(original[key] is JsonObject incomingObject){var merged=(state[key] as JsonObject)?.DeepClone().AsObject()??new JsonObject();foreach(var pair in incomingObject)if(!merged.ContainsKey(pair.Key))merged[pair.Key]=pair.Value?.DeepClone();state[key]=merged;}
                else if(state[key]==null)state[key]=original[key]?.DeepClone();
            }
            File.WriteAllText(statePath,state.ToJsonString());
        }
    }
    static void Restore(string home,string marker){
        if(!File.Exists(marker))return;var data=JsonNode.Parse(File.ReadAllText(marker))!.AsObject();var source=data["source"]!.GetValue<string>();
        foreach(var name in new[]{"sessions","archived_sessions"}){var link=Path.Combine(home,name);if(!Directory.Exists(link))continue;if((File.GetAttributes(link)&FileAttributes.ReparsePoint)==0||!NativePlatform.SamePath(new DirectoryInfo(link).ResolveLinkTarget(true)!.FullName,Path.Combine(source,name)))throw new AppError("The local workspace paths could not be verified.");Directory.Delete(link);}
        var path=Path.Combine(home,".codex-global-state.json");Repository.RejectLinks(path);var state=File.Exists(path)?JsonNode.Parse(File.ReadAllText(path))!.AsObject():new JsonObject();var old=data["previous"]!.AsObject();foreach(var key in Keys){if(old.ContainsKey(key))state[key]=old[key]?.DeepClone();else state.Remove(key);}File.WriteAllText(path,state.ToJsonString());File.Delete(marker);
    }
    static async Task JunctionAsync(string link,string target){
        var info=new ProcessStartInfo("powershell.exe"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
        foreach(var arg in new[]{"-NoProfile","-NonInteractive","-Command","New-Item -ItemType Junction -Path $env:AISW_LINK -Target $env:AISW_TARGET -ErrorAction Stop | Out-Null"})info.ArgumentList.Add(arg);info.Environment["AISW_LINK"]=link;info.Environment["AISW_TARGET"]=target;
        using var process=Process.Start(info)??throw new AppError("The local workspace paths could not be verified.");var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));await output;await error;if(process.ExitCode!=0)throw new AppError("The local workspace paths could not be verified.");
    }
}
