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
    public Localizer L=>new(Preferences.Language);
    public Theme Theme=>Themes.Get(Preferences.Theme);
    public HashSet<Guid> Busy { get; }=[];
    public Dictionary<Guid,string> Errors { get; }=[];
    public Dictionary<Guid,DateTimeOffset> Checks { get; }=[];
    public bool ReadOnly { get; private set; }
    public string? LoadError { get; private set; }
    public string? LifecycleError { get; private set; }
    public event Action? Changed;
    public event Action<string>? Error;
    public event Action<Account,IReadOnlyList<QuotaAlert>>? QuotaAlert;
    readonly CancellationTokenSource lifetime=new();bool observing;DateTimeOffset lastSweep=DateTimeOffset.MinValue;
    public AppEngine(string root){
        Repository=new(root);
        try{Preferences=Repository.LoadPreferences();Snapshot=Repository.Load();}catch(Exception error){ReadOnly=true;LoadError=Message(error);}
        Platform=new(Repository,Preferences);Backend=new(Repository,Platform,Preferences);
    }
    public void Notify()=>Changed?.Invoke();
    public void SavePreferences(){if(ReadOnly){Notify();return;}try{Repository.SavePreferences(Preferences);Notify();}catch(Exception error){Error?.Invoke(Message(error));}}
    public void SetQuotaOnly(bool enabled){Preferences.SetQuotaOnly(enabled);SavePreferences();}
    public void SetAgent(Agent? agent){Preferences.AgentFilter=agent;SavePreferences();}
    public async Task<bool> SetExecutableAsync(string key,string? path){
        if(ReadOnly)return false;
        try{
            await Platform.RefreshProcessesAsync();
            if(Snapshot.Accounts.Any(a=>(NativePlatform.ExecutableKey(a)==key||key=="codex"&&a.UsesCodexDesktop)&&(Busy.Contains(a.Id)||Running(a))))throw new AppError("Close running sessions before changing their application executable.");
            if(path==null)Preferences.Executables.Remove(key);else Preferences.Executables[key]=path;
            Platform.InvalidateDiscovery();Repository.SavePreferences(Preferences);Notify();return true;
        }catch(Exception error){Error?.Invoke(Message(error));return false;}
    }
    public string Message(Exception error)=>L[error is AppError app?app.Key:"The operation failed. Your existing data has been preserved."];
    public bool Running(Account a)=>a.Agent.IsShared()?Platform.Processes.Any(p=>Path.GetFileName(p.Executable).Equals("Antigravity.exe",StringComparison.OrdinalIgnoreCase)):Platform.Owned(a)!=null||Backend.IsActive(a)||Backend.HasSocket(a);
    public bool CanConnect(Account a)=>a.UsesCodexDesktop&&!ReadOnly&&!Busy.Contains(a.Id)&&!Running(a);
    public string Status(Account a)=>Busy.Contains(a.Id)?L["Working…"]:Errors.GetValueOrDefault(a.Id)==L["The Codex session is signed out or expired. Reconnect the account."]?L["Sign-in required"]:a.Agent.IsShared()?(Running(a)?L["Application running"]:L["Disconnected"]):Platform.Owned(a) is {HasWindow:true}?(a.EffectiveMode==LaunchMode.Browser?L["Browser running"]:L["Desktop window open"]):Backend.IsActive(a)?L["Running in background"]:Errors.ContainsKey(a.Id)?L["Connection failed"]:L["Disconnected"];
    public bool DefaultConnect(Account a)=>a.UsesCodexDesktop&&(Preferences.QuotaOnlyMode||a.DefaultAction==DefaultAction.ConnectSession);
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
        if(ReadOnly)return false;
        try{
            edited.Validate();var old=Snapshot.Accounts.FirstOrDefault(x=>x.Id==edited.Id);
            if(old!=null){if(old.Agent!=edited.Agent||old.Browser!=edited.Browser)throw new AppError("The agent of an existing profile cannot change. Create a new profile instead.");
                if((old.EffectiveMode!=edited.EffectiveMode||old.SharesLocalWorkspace!=edited.SharesLocalWorkspace)&&(Running(old)||Busy.Contains(old.Id)))throw new AppError("Close the session from the ⋯ menu and wait for quota operations to finish before changing modes.");
                edited=edited with{DesktopConnection=old.DesktopConnection,BrowserConnection=old.BrowserConnection,LastOpenedAt=old.LastOpenedAt};
            }
            var updated=Snapshot with{Accounts=Snapshot.Accounts.Where(x=>x.Id!=edited.Id).Append(edited).OrderBy(x=>x.CreatedAt).ToList()};Repository.Save(updated);Snapshot=updated;Notify();return true;
        }catch(Exception error){Error?.Invoke(Message(error));return false;}
    }
    public void ToggleFavorite(Account a)=>SaveAccount(a with{IsFavorite=!a.IsFavorite});
    Account Current(Account a)=>Snapshot.Accounts.First(x=>x.Id==a.Id);
    async Task Run(Account a,Func<Task> action,bool report=true){
        if(ReadOnly||lifetime.IsCancellationRequested||!Snapshot.Accounts.Any(x=>x.Id==a.Id)||!Busy.Add(a.Id))return;Notify();
        try{await action();Errors.Remove(a.Id);}catch(OperationCanceledException){}catch(Exception error){Errors[a.Id]=Message(error);if(report)Error?.Invoke(Message(error));}
        finally{Busy.Remove(a.Id);try{await Platform.RefreshProcessesAsync();}catch{LifecycleError=L["Process status could not be checked. Retry from Session diagnostics."];}Notify();}
    }
    public Task OpenAsync(Account a)=>Run(a,async()=>{
        if(a.UsesCodexDesktop)await Backend.StartAsync(a);
        await Platform.OpenAsync(a);var current=Current(a);current.LastOpenedAt=DateTimeOffset.UtcNow;Snapshot.LastOpenedId=a.Id;Repository.Save(Snapshot);
    });
    public Task ConnectAsync(Account a,bool report=true){if(!CanConnect(a))return Task.CompletedTask;return Run(a,async()=>{await Backend.StartAsync(a);await ReadAsync(a);},report);}
    public Task RefreshAsync(Account a,bool report=true){if(!a.Agent.HasQuota())return Task.CompletedTask;return Run(a,()=>ReadAsync(a),report);}
    async Task ReadAsync(Account a){
        Checks[a.Id]=DateTimeOffset.UtcNow;
        try{
            var connection=await Backend.ReadAsync(a,lifetime.Token);var current=Current(a);
            if(!a.UsesCodexDesktop&&current.BrowserConnection is { } verified&&!verified.Identity.Matches(connection.Identity))throw new AppError("The Codex account changed. Disconnect, then verify the intended account for this profile again.");
            if(current.UsesCodexDesktop)current.DesktopConnection=connection;else current.BrowserConnection=connection;
            Repository.Save(Snapshot);var alerts=AlertTracker.Evaluate(current,Preferences,DateTimeOffset.UtcNow);Repository.SavePreferences(Preferences);if(alerts.Count>0)QuotaAlert?.Invoke(current,alerts);
        }catch(AppError error)when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){
            if(a.UsesCodexDesktop){Current(a).DesktopConnection=null;Repository.Save(Snapshot);}throw;
        }
    }
    public Task CloseAsync(Account a)=>Run(a,async()=>{if(a.Agent.IsShared())return;await Platform.CloseAsync(a);if(a.UsesCodexDesktop)await Backend.StopAsync(a);});
    public Task RestartAsync(Account a){if(!a.UsesCodexDesktop)return Task.CompletedTask;return Run(a,async()=>{await Platform.CloseAsync(a);await Backend.StopAsync(a);await Backend.StartAsync(a);await ReadAsync(a);});}
    public Task DeleteAsync(Account a)=>Run(a,async()=>{await Platform.RefreshProcessesAsync();if(Running(a)&&!a.Agent.IsShared())throw new AppError("Close this session before deleting its profile.");if(a.UsesCodexDesktop)SharedWorkspace.Archive(a,Repository);Snapshot=Repository.Remove(a,Snapshot);});
    public Task BrowserLoginAsync(Account a,Func<Identity,Task<bool>> confirm,CancellationToken ct)=>Run(a,async()=>{
        if(!a.Agent.HasQuota()||a.EffectiveMode!=LaunchMode.Browser)return;
        await using var client=await Backend.StdioClientAsync(a,ct);var login=await client.StartLoginAsync(ct);bool confirmed=false;
        try{
            await Platform.OpenAsync(a,login.Url);await client.WaitForLoginAsync(login.Id,ct);var identity=await client.ReadIdentityAsync(ct);
            if(!await confirm(identity))return;var connection=await client.ReadQuotaAsync(ct);if(!identity.Matches(connection.Identity))throw new AppError("The Codex account changed. Disconnect, then verify the intended account for this profile again.");
            Current(a).BrowserConnection=connection;Repository.Save(Snapshot);confirmed=true;
        }finally{if(!confirmed){try{await client.CancelLoginAsync(login.Id);await client.LogoutAsync();}catch{}}}
    });
    public Task DisconnectBrowserAsync(Account a)=>Run(a,async()=>{if(a.EffectiveMode!=LaunchMode.Browser||!a.Agent.HasQuota())return;await using var client=await Backend.StdioClientAsync(a,lifetime.Token);await client.LogoutAsync(lifetime.Token);Current(a).BrowserConnection=null;Repository.Save(Snapshot);});
    public async Task ObserveAsync(bool refresh=true){
        if(observing||ReadOnly||lifetime.IsCancellationRequested)return;observing=true;
        try{
            await Platform.RefreshProcessesAsync();LifecycleError=null;
            foreach(var a in Snapshot.Accounts.Where(x=>x.UsesCodexDesktop&&!Busy.Contains(x.Id)))if(!Backend.IsActive(a))await Backend.DiscoverAsync(a);
            Notify();if(!refresh)return;
            var sweep=DateTimeOffset.UtcNow-lastSweep>TimeSpan.FromMinutes(5);
            foreach(var account in Snapshot.Accounts.ToArray()){
                if(Busy.Contains(account.Id)||!account.Agent.HasQuota())continue;
                var active=account.UsesCodexDesktop?Backend.IsActive(account):account.BrowserConnection!=null;
                var missing=account.UsesCodexDesktop&&active&&account.Connection?.Quota==null&&(!Checks.TryGetValue(account.Id,out var checkedAt)||DateTimeOffset.UtcNow-checkedAt>TimeSpan.FromSeconds(30));
                if(active&&(sweep||missing))await RefreshAsync(account,false);
            }
            if(sweep)lastSweep=DateTimeOffset.UtcNow;
        }catch(Exception error){LifecycleError=Message(error);Notify();}finally{observing=false;}
    }
    public void Shutdown(){lifetime.Cancel();}
}
