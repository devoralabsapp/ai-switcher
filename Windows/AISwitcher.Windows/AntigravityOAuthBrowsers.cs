using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal sealed partial class NativePlatform {
    readonly Dictionary<Guid,Dictionary<(int Id,long Created),string>> oauthBrowsers=[];
    internal async Task<IReadOnlyList<OwnedProcess>> AntigravityOAuthBrowsersAsync(Account account){
        if(!account.UsesPrivateAntigravity)return [];
        AntigravityProfile.Validate(repository,account);
        var local=Path.Combine(AntigravityProfile.Home(repository,account),"AppData","Local");
        var profiles=new[]{("edge","Microsoft/Edge/User Data"),("chrome","Google/Chrome/User Data"),("brave","BraveSoftware/Brave-Browser/User Data")};
        foreach(var (key,relative) in profiles){
            var directory=Path.Combine(local,relative);var parent=directory;
            while(parent.Length>=local.Length){Repository.RejectLinks(parent);if(SamePath(parent,local))break;parent=Path.GetDirectoryName(parent)!;}
            var files=new[]{Path.Combine(directory,"lockfile"),Path.Combine(directory,"Local State")};foreach(var file in files)Repository.RejectLinks(file);
            files=files.Where(File.Exists).ToArray();if(files.Length==0)continue;
            var executable=await FindExecutableAsync(key);if(executable==null)continue;
            // Windows may start the default browser through a broker, so ancestry
            // is insufficient. Require a live PID/start time that Restart Manager
            // proves has this exact private browser storage open, plus the known
            // installed executable. Never adopt the user's regular browser.
            var users=await Task.Run(()=>ProfileQuit.ResourceUsers(files));
            foreach(var user in users){
                var process=processes.FirstOrDefault(p=>p.Id==user.Id&&p.Created==user.Created&&SamePath(p.Executable,executable)&&!p.Arguments.Any(x=>x.StartsWith("--type=",StringComparison.OrdinalIgnoreCase)));
                if(process==null)continue;
                var specified=process.Arguments.FirstOrDefault(x=>x.StartsWith("--user-data-dir=",StringComparison.OrdinalIgnoreCase));
                if(specified!=null&&!SamePath(specified[16..],directory))continue;
                if(!oauthBrowsers.TryGetValue(account.Id,out var roots))oauthBrowsers[account.Id]=roots=[];
                roots[(process.Id,process.Created)]=executable;
                if(!tracked.TryGetValue(account.Id,out var family))tracked[account.Id]=family=[];
                family[(process.Id,process.Created)]=process;
            }
        }
        TrackChildren(account.Id);
        return oauthBrowsers.TryGetValue(account.Id,out var owned)?processes.Where(p=>owned.TryGetValue((p.Id,p.Created),out var exe)&&SamePath(p.Executable,exe)).ToArray():[];
    }
    bool IsOAuthBrowser(Account account,OwnedProcess process)=>account.UsesPrivateAntigravity&&oauthBrowsers.TryGetValue(account.Id,out var roots)&&roots.Values.Any(exe=>SamePath(exe,process.Executable));
    async Task CloseAntigravityOAuthBrowsersAsync(Account account){
        await RefreshProcessesAsync();var roots=await AntigravityOAuthBrowsersAsync(account);
        foreach(var root in roots){
            try{using var process=Process.GetProcessById(root.Id);_=process.SafeHandle;
                if(process.HasExited||process.StartTime.ToUniversalTime().ToFileTimeUtc()!=root.Created||!SamePath(process.MainModule!.FileName!,root.Executable))continue;
                try{await ProfileQuit.RequestAsync(root.Id,root.Created);}catch(AppError)when(process.HasExited){}
                try{await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));}catch(TimeoutException){throw new AppError("This profile did not agree to quit. Finish any confirmation in its window or use its own tray Quit action, then retry.");}
                exitedParents[(root.Id,root.Created)]=process.ExitTime.ToUniversalTime().ToFileTimeUtc();
            }catch(ArgumentException){}
        }
    }
}
