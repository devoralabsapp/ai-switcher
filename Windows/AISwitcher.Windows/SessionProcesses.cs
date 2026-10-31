using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal sealed partial class NativePlatform {
    readonly Dictionary<(int Id,long Created),long> exitedParents=[];
    public bool HasOwnedProcesses(Account account)=>SessionProcesses(account).Count>0;
    internal IReadOnlyList<OwnedProcess> SessionProcesses(Account account){
        Owned(account);if(!tracked.TryGetValue(account.Id,out var family))return [];
        return processes.Where(p=>family.ContainsKey((p.Id,p.Created))&&SamePath(p.Executable,family[(p.Id,p.Created)].Executable)&&IsSessionRuntime(account,p)).ToArray();
    }
    bool IsSessionRuntime(Account account,OwnedProcess process){
        if(IsAgentExecutable(account,process.Executable))return true;
        // Native Codex helpers inherit ownership from a verified live parent or its
        // exact exit lifetime. Matching a global executable name is never sufficient.
        var name=Path.GetFileName(process.Executable);
        return account.UsesCodexDesktop&&(name.Equals("codex.exe",StringComparison.OrdinalIgnoreCase)||name.Equals("codex-cli.exe",StringComparison.OrdinalIgnoreCase));
    }
    internal async Task CompleteCloseAsync(Account account){
        // Give renderers and the app-server a short opportunity to follow the root.
        var empty=0;for(var i=0;i<6;i++){
            await RefreshProcessesAsync();if(SessionProcesses(account).Count==0){if(++empty>=2)return;}else empty=0;
            await Task.Delay(250);
        }
        repository.ValidateOwned(repository.ProfilePath(account),account.Id);
        for(var pass=0;pass<3;pass++){
            await RefreshProcessesAsync();var remaining=SessionProcesses(account);
            if(remaining.Count==0)return;
            // A newly opened root or visible window must finish its own quit flow.
            if(Owned(account)!=null||remaining.Any(p=>p.HasWindow))throw new AppError("Some account processes could not be stopped. Check Session diagnostics and try again.");
            foreach(var target in remaining.OrderByDescending(p=>p.Created)){
                if(target.Id==Environment.ProcessId)continue;
                try{using var process=Process.GetProcessById(target.Id);
                    _=process.SafeHandle; // ExitTime must remain readable after Windows reaps the PID.
                    if(process.HasExited||process.StartTime.ToUniversalTime().ToFileTimeUtc()!=target.Created)continue;
                    if(process.MainWindowHandle!=IntPtr.Zero)throw new AppError("Some account processes could not be stopped. Check Session diagnostics and try again.");
                    // The root already agreed to quit (or was closed manually).
                    // Finish only headless helpers proven to belong to this profile.
                    process.Kill();await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
                    exitedParents[(target.Id,target.Created)]=process.ExitTime.ToUniversalTime().ToFileTimeUtc();
                }catch(ArgumentException){}catch(System.ComponentModel.Win32Exception)when(!StillSameProcess(target)){}
            }
        }
        await VerifyClosedAsync(account);
    }
    internal async Task VerifyClosedAsync(Account account){
        if(account.Agent.IsShared())return;await RefreshProcessesAsync();
        if(HasOwnedProcesses(account))throw new AppError("Some account processes could not be stopped. Check Session diagnostics and try again.");
        if(tracked.Remove(account.Id,out var family))foreach(var key in family.Keys)exitedParents.Remove(key);
    }
}
