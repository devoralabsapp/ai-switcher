using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal sealed class AppEngine {
    public Repository Repository { get; }
    public Snapshot Snapshot { get; private set; }=new();
    public Preferences Preferences { get; private set; }=new();
    public NativePlatform Platform { get; }
    public BackendService Backend { get; }
    public ProviderQuotaService Provider { get; }
    public Localizer L=>new(Preferences.Language);
    public Theme Theme=>Themes.Get(Preferences.Theme);
    public HashSet<Guid> Busy { get; }=[];
    public HashSet<Agent> InstallingProviders { get; }=[];
    public Dictionary<Agent,string> InstallationErrors { get; }=[];
    readonly Dictionary<Agent,Task> installationTasks=[];
    public Dictionary<Guid,string> Errors { get; }=[];
    public Dictionary<Guid,DateTimeOffset> Checks { get; }=[];
    public bool ReadOnly { get; private set; }
    public string? LoadError { get; private set; }
    public string? LifecycleError { get; private set; }
    public event Action? Changed;
    public event Action<string>? Error;
    internal Action<Exception>? FixtureFailure { get; set; }
    public event Action<Account,IReadOnlyList<QuotaAlert>>? QuotaAlert;
    sealed record Operation(CancellationTokenSource Cancellation,TaskCompletionSource Completion);
    readonly Dictionary<Guid,Operation> operations=[];
    public bool StoppingAll { get; private set; }
    readonly CancellationTokenSource lifetime=new();bool observing;DateTimeOffset lastSweep=DateTimeOffset.MinValue;
    public AppEngine(string root){
        Repository=new(root);
        try{Preferences=Repository.LoadPreferences();Snapshot=Repository.Load();}catch(Exception error){ReadOnly=true;LoadError=Message(error);}
        Platform=new(Repository,Preferences);Platform.PreparationChanged+=Notify;Backend=new(Repository,Platform,Preferences);Provider=new(Repository,Preferences);
    }
    public void Notify()=>Changed?.Invoke();
    public void SavePreferences(){if(ReadOnly){Notify();return;}try{Repository.SavePreferences(Preferences);Notify();}catch(Exception error){Error?.Invoke(Message(error));}}
    public void SetQuotaOnly(bool enabled){Preferences.SetQuotaOnly(enabled);SavePreferences();}
    public void SetAgent(Agent? agent){Preferences.AgentFilter=agent;SavePreferences();}
    public async Task<bool> SetExecutableAsync(string key,string? path){
        if(ReadOnly||StoppingAll)return false;
        try{
            await Platform.RefreshProcessesAsync();
            if(Snapshot.Accounts.Any(a=>(NativePlatform.ExecutableKey(a)==key||key=="codex"&&a.UsesCodexDesktop||a.Agent.ProviderQuota()&&ProviderQuotaService.Key(a.Agent)==key)&&(Busy.Contains(a.Id)||Running(a))))throw new AppError("Close running sessions before changing their application executable.");
            if(path==null)Preferences.Executables.Remove(key);else Preferences.Executables[key]=path;
            Platform.InvalidateDiscovery();Repository.SavePreferences(Preferences);Notify();return true;
        }catch(Exception error){Error?.Invoke(Message(error));return false;}
    }
    public string Message(Exception error)=>error is System.ComponentModel.Win32Exception native?L.Format("Windows could not start the application (error %@). Check Session diagnostics and the executable paths in Settings.",native.NativeErrorCode):error is UnauthorizedAccessException?L["Windows denied access to an application or profile folder. Open ChatGPT from Start once, then retry. Do not change WindowsApps permissions."]:L[error is AppError app?app.Key:"The operation failed. Your existing data has been preserved."];
    public bool Running(Account a)=>Provider.Connected.Contains(a.Id)|| (a.Agent.IsShared()?Platform.Processes.Any(p=>Path.GetFileName(p.Executable).Equals("Antigravity.exe",StringComparison.OrdinalIgnoreCase)):Platform.HasOwnedProcesses(a)||Backend.IsActive(a));
    public bool CanConnect(Account a)=>(a.UsesCodexDesktop||a.Agent.ProviderQuota())&&!ReadOnly&&!StoppingAll&&!InstallingProviders.Contains(a.Agent)&&!Busy.Contains(a.Id)&&!(a.Agent.ProviderQuota()?Provider.Connected.Contains(a.Id):Running(a));
    public string Status(Account a)=>StoppingAll||Busy.Contains(a.Id)?L[Platform.PreparingRuntime.Contains(a.Id)?a.Agent==Agent.Claude?"Preparing Claude for the first launch…":"Preparing ChatGPT for the first launch…":"Working…"]:Errors.GetValueOrDefault(a.Id)==L["The Codex session is signed out or expired. Reconnect the account."]?L["Sign-in required"]:Provider.Connected.Contains(a.Id)?L["Running in background"]:a.Agent.IsShared()?(Running(a)?L["Application running"]:L["Disconnected"]):Platform.Owned(a) is {HasWindow:true}?(a.EffectiveMode==LaunchMode.Browser?L["Browser running"]:L["Desktop window open"]):Platform.HasOwnedProcesses(a)||Backend.IsActive(a)?L["Running in background"]:Errors.ContainsKey(a.Id)?L["Connection failed"]:L["Disconnected"];
    public bool DefaultConnect(Account a)=>(a.UsesCodexDesktop||a.Agent.ProviderQuota())&&(Preferences.QuotaOnlyMode||a.DefaultAction==DefaultAction.ConnectSession);
    public string DefaultTitle(Account a)=>DefaultConnect(a)?Running(a)?L["Refresh quota"]:L["Connect account session"]:L.Format("Open %@",a.Agent.Name());
    public Task DefaultAsync(Account a)=>DefaultConnect(a)?Running(a)?RefreshAsync(a):ConnectAsync(a):OpenAsync(a);
    public async Task InitializeAsync(){
        if(ReadOnly){Notify();return;}
        foreach(var key in new[]{"chrome","edge","brave","chatgpt","claude","antigravity","codex"})await Platform.FindExecutableAsync(key);
        await ObserveAsync(false);
        foreach(var account in Snapshot.Accounts.Where(x=>x.UsesCodexDesktop&&x.ConnectOnStartup).ToArray())if(!lifetime.IsCancellationRequested&&!Running(account))await ConnectAsync(account,false);
        await ObserveAsync();
    }
    public bool SaveAccount(Account edited){
        if(ReadOnly||StoppingAll)return false;
        try{
            edited.Validate();var old=Snapshot.Accounts.FirstOrDefault(x=>x.Id==edited.Id);
            if(old!=null){if(old.Agent!=edited.Agent||old.Browser!=edited.Browser)throw new AppError("The agent of an existing profile cannot change. Create a new profile instead.");
                if((old.EffectiveMode!=edited.EffectiveMode||old.SharesLocalWorkspace!=edited.SharesLocalWorkspace)&&(Running(old)||Busy.Contains(old.Id)))throw new AppError("Close the session from the ⋯ menu and wait for quota operations to finish before changing modes.");
                edited=edited with{ProviderConnection=old.ProviderConnection,DesktopConnection=old.DesktopConnection,BrowserConnection=old.BrowserConnection,LastOpenedAt=old.LastOpenedAt};
            }
            var updated=Snapshot with{Accounts=Snapshot.Accounts.Where(x=>x.Id!=edited.Id).Append(edited).OrderBy(x=>x.CreatedAt).ToList()};Repository.Save(updated);Snapshot=updated;Notify();return true;
        }catch(Exception error){Error?.Invoke(Message(error));return false;}
    }
    public void ToggleFavorite(Account a)=>SaveAccount(a with{IsFavorite=!a.IsFavorite});
    Account Current(Account a)=>Snapshot.Accounts.First(x=>x.Id==a.Id);
    async Task Run(Account a,Func<CancellationToken,Task> action,bool report=true){
        if(ReadOnly||StoppingAll||InstallingProviders.Contains(a.Agent)||lifetime.IsCancellationRequested||!Snapshot.Accounts.Any(x=>x.Id==a.Id)||!Busy.Add(a.Id))return;
        using var cancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);var operation=new Operation(cancellation,new(TaskCreationOptions.RunContinuationsAsynchronously));operations[a.Id]=operation;Notify();
        try{Errors.Remove(a.Id);await action(cancellation.Token);}catch(OperationCanceledException)when(!cancellation.IsCancellationRequested){Errors[a.Id]=L["The provider quota request timed out. Try again."];}catch(OperationCanceledException){}catch(Exception error){FixtureFailure?.Invoke(error);Errors[a.Id]=Message(error);if(report)Error?.Invoke(Message(error));}
        finally{Busy.Remove(a.Id);try{await Platform.RefreshProcessesAsync();}catch{LifecycleError=L["Process status could not be checked. Retry from Session diagnostics."];}operations.Remove(a.Id);operation.Completion.TrySetResult();Notify();}
    }
    public Task OpenAsync(Account a)=>Run(a,async ct=>{
        string? backgroundError=null;
        if(a.UsesCodexDesktop){Repository.PrepareQuota(a);Repository.PrepareProfile(a);await SharedWorkspace.PrepareAsync(a,Repository,Preferences);try{await Backend.StartAsync(a,ct);}catch(Exception error)when(error is AppError or System.ComponentModel.Win32Exception){backgroundError=Message(error);}}
        await Platform.OpenAsync(a,useLocalDaemon:Backend.UsesLocalDaemon(a),ct:ct);var current=Current(a);current.LastOpenedAt=DateTimeOffset.UtcNow;Snapshot.LastOpenedId=a.Id;Repository.Save(Snapshot);
        if(backgroundError!=null)Errors[a.Id]=backgroundError;
    });
    public Task ConnectAsync(Account a,bool report=true){if(!CanConnect(a))return Task.CompletedTask;return Run(a,async ct=>{if(!a.Agent.ProviderQuota())await Backend.StartAsync(a,ct);await ReadAsync(a,ct);},report);}
    public Task InstallProviderAsync(Account a){
        if(!a.Agent.ProviderQuota()||ReadOnly||StoppingAll||lifetime.IsCancellationRequested||Busy.Contains(a.Id)||!Snapshot.Accounts.Any(x=>x.Id==a.Id)||!InstallingProviders.Add(a.Agent))return Task.CompletedTask;
        InstallationErrors.Remove(a.Agent);Notify();
        // Yield in the worker before completing so its task is registered before cleanup.
        var task=Install();installationTasks[a.Agent]=task;return task;
        async Task Install(){
            await Task.Yield();
            try{
                var job=new ProviderCLIInstallation(a.Agent,Repository.Root);job.Prepare();
                try{
                    var shell=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
                    var info=new System.Diagnostics.ProcessStartInfo(shell){UseShellExecute=true};
                    foreach(var arg in new[]{"-NoProfile","-NoExit","-ExecutionPolicy","Bypass","-File",job.Launcher})info.ArgumentList.Add(arg);
                    using var launched=System.Diagnostics.Process.Start(info)??throw new AppError(ProviderCLIInstallation.Failed);
                    await job.WaitAsync(lifetime.Token);
                    if(!Snapshot.Accounts.Any(x=>x.Id==a.Id))return;
                    using var verification=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);verification.CancelAfter(TimeSpan.FromSeconds(30));
                    var executable=await Provider.VerifyInstalledAsync(a,verification.Token);
                    Preferences.Executables[ProviderQuotaService.Key(a.Agent)]=executable;Repository.SavePreferences(Preferences);
                    foreach(var profile in Snapshot.Accounts.Where(x=>x.Agent==a.Agent))Errors.Remove(profile.Id);
                    InstallingProviders.Remove(a.Agent);Notify();
                    var current=Snapshot.Accounts.FirstOrDefault(x=>x.Id==a.Id);if(current!=null)await ConnectAsync(current);
                }finally{job.CleanupIfFinished();}
            }catch(OperationCanceledException)when(lifetime.IsCancellationRequested){}
            catch(Exception error){InstallationErrors[a.Agent]=error is OperationCanceledException?L[ProviderCLIInstallation.Failed]:Message(error);}
            finally{InstallingProviders.Remove(a.Agent);installationTasks.Remove(a.Agent);Notify();}
        }
    }
    public Task RefreshAsync(Account a,bool report=true){if(!a.Agent.HasQuota())return Task.CompletedTask;return Run(a,ct=>ReadAsync(a,ct),report);}
    async Task ReadAsync(Account a,CancellationToken ct){
        Checks[a.Id]=DateTimeOffset.UtcNow;
        try{
            var connection=a.Agent.ProviderQuota()?await Provider.ReadAsync(a,ct):await Backend.ReadAsync(a,ct);var current=Current(a);
            if(!a.Agent.ProviderQuota()&&!a.UsesCodexDesktop&&current.BrowserConnection is { } verified&&!verified.Identity.Matches(connection.Identity))throw new AppError("The Codex account changed. Disconnect, then verify the intended account for this profile again.");
            if(current.Agent.ProviderQuota()){current.ProviderConnection=connection;Provider.Connected.Add(a.Id);}else if(current.UsesCodexDesktop)current.DesktopConnection=connection;else current.BrowserConnection=connection;
            Repository.Save(Snapshot);var alerts=AlertTracker.Evaluate(current,Preferences,DateTimeOffset.UtcNow);Repository.SavePreferences(Preferences);if(alerts.Count>0)QuotaAlert?.Invoke(current,alerts);
        }catch(AppError error)when(a.Agent.ProviderQuota()&&(error.Key==ProviderQuota.SignedOut||error.Key==ProviderQuota.Changed)){
            Provider.Connected.Remove(a.Id);throw;
        }catch(AppError error)when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){
            if(a.UsesCodexDesktop){Current(a).DesktopConnection=null;Repository.Save(Snapshot);}throw;
        }
    }
    public Task CloseAsync(Account a)=>Run(a,async ct=>{if(a.Agent.ProviderQuota())await Provider.DisconnectAsync(a);if(a.Agent.IsShared())return;await Platform.CloseAsync(a);if(a.UsesCodexDesktop)await Backend.StopAsync(a);await Platform.VerifyClosedAsync(a);});
    public Task RestartAsync(Account a){if(!a.UsesCodexDesktop)return Task.CompletedTask;return Run(a,async ct=>{await Platform.CloseAsync(a);await Backend.StopAsync(a);await Backend.StartAsync(a,ct);await ReadAsync(a,ct);});}
    public Task DeleteAsync(Account a)=>Run(a,async ct=>{await Platform.RefreshProcessesAsync();if(Running(a)&&!a.Agent.IsShared())throw new AppError("Close this session before deleting its profile.");if(a.UsesCodexDesktop)SharedWorkspace.Archive(a,Repository);Snapshot=Repository.Remove(a,Snapshot);});
    public Task BrowserLoginAsync(Account a,Func<Identity,Task<bool>> confirm,CancellationToken externalCt)=>Run(a,async operationCt=>{
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(operationCt,externalCt);var ct=linked.Token;
        if(a.Agent!=Agent.Chatgpt||a.EffectiveMode!=LaunchMode.Browser)return;
        await using var client=await Backend.StdioClientAsync(a,ct);var login=await client.StartLoginAsync(ct);bool confirmed=false;
        try{
            await Platform.OpenAsync(a,login.Url,ct:ct);await client.WaitForLoginAsync(login.Id,ct);var identity=await client.ReadIdentityAsync(ct);
            if(!await confirm(identity))return;var connection=await client.ReadQuotaAsync(ct);if(!identity.Matches(connection.Identity))throw new AppError("The Codex account changed. Disconnect, then verify the intended account for this profile again.");
            Current(a).BrowserConnection=connection;Repository.Save(Snapshot);confirmed=true;
        }finally{if(!confirmed){try{await client.CancelLoginAsync(login.Id);await client.LogoutAsync();}catch{}}}
    });
    public Task DisconnectBrowserAsync(Account a)=>Run(a,async ct=>{if(a.EffectiveMode!=LaunchMode.Browser||a.Agent!=Agent.Chatgpt)return;await using var client=await Backend.StdioClientAsync(a,ct);await client.LogoutAsync(ct);Current(a).BrowserConnection=null;Repository.Save(Snapshot);});
    public async Task ObserveAsync(bool refresh=true){
        if(observing||ReadOnly||StoppingAll||lifetime.IsCancellationRequested)return;observing=true;
        try{
            await Platform.RefreshProcessesAsync();LifecycleError=null;
            foreach(var a in Snapshot.Accounts.Where(x=>x.UsesCodexDesktop&&!Busy.Contains(x.Id)))await Backend.DiscoverAsync(a);
            Notify();if(!refresh||StoppingAll)return;
            var sweep=DateTimeOffset.UtcNow-lastSweep>TimeSpan.FromMinutes(5);
            foreach(var account in Snapshot.Accounts.ToArray()){
                if(StoppingAll)return;
                if(Busy.Contains(account.Id)||!account.Agent.HasQuota())continue;
                var active=account.Agent.ProviderQuota()?Provider.Connected.Contains(account.Id):account.UsesCodexDesktop?Backend.IsActive(account)||Platform.Owned(account)!=null:account.BrowserConnection!=null;
                var missing=account.UsesCodexDesktop&&active&&account.Connection?.Quota==null&&(!Checks.TryGetValue(account.Id,out var checkedAt)||DateTimeOffset.UtcNow-checkedAt>TimeSpan.FromSeconds(30));
                if(active&&(sweep||missing))await RefreshAsync(account,false);
            }
            if(sweep)lastSweep=DateTimeOffset.UtcNow;
        }catch(Exception error){LifecycleError=Message(error);Notify();}finally{observing=false;}
    }
    public async Task ForceStopAllAsync(){
        if(ReadOnly||StoppingAll)return;StoppingAll=true;Backend.Suspended=true;Notify();
        var pending=operations.Values.ToArray();foreach(var op in pending)op.Cancellation.Cancel();
        try{
            try{await Task.WhenAll(pending.Select(op=>op.Completion.Task)).WaitAsync(TimeSpan.FromSeconds(25));}catch(TimeoutException){}
            var failed=false;
            foreach(var account in Snapshot.Accounts.ToArray()){
                Errors.Remove(account.Id);
                await Provider.DisconnectAsync(account);
                try{using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(8));await Backend.StopAsync(account,timeout.Token);}catch(Exception error){Errors[account.Id]=Message(error);failed=true;}
                try{await Platform.ForceStopAsync(account);}catch(Exception error){Errors[account.Id]=Message(error);failed=true;}
            }
            if(failed)Error?.Invoke(L["Some account processes could not be stopped. Check Session diagnostics and try again."]);
        }finally{StoppingAll=false;Backend.Suspended=false;try{await Platform.RefreshProcessesAsync();}catch{LifecycleError=L["Process status could not be checked. Retry from Session diagnostics."];}Notify();}
    }
    public async Task ShutdownAsync(){lifetime.Cancel();await Task.WhenAll(installationTasks.Values.ToArray());await Backend.ShutdownAsync();foreach(var a in Snapshot.Accounts)await Provider.DisconnectAsync(a);}
    public void Shutdown(){_=ShutdownAsync();}
}
