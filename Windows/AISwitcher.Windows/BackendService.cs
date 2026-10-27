using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal sealed class BackendService {
    // Used only by the explicitly disposable, signed-out Windows CI fixture.
    internal Action<string>? FixtureDiagnostic { get; set; }
    readonly Repository repository;readonly NativePlatform platform;readonly Preferences preferences;
    sealed record Session(StdioTransport Transport,RpcClient Client){public bool Ready { get; set; }}
    readonly Dictionary<Guid,Session> sessions=[];
    public bool Suspended { get; set; }
    readonly HashSet<Guid> active=[]; // Verified legacy daemons only; a socket file alone is never a connection.
    readonly Dictionary<Guid,DateTimeOffset> probes=[];
    public BackendService(Repository repository,NativePlatform platform,Preferences preferences){this.repository=repository;this.platform=platform;this.preferences=preferences;}
    public string SocketPath(Account account)=>Path.Combine(repository.QuotaHome(account),"app-server-control","app-server-control.sock");
    public bool HasSocket(Account account)=>account.UsesCodexDesktop&&File.Exists(SocketPath(account));
    public bool UsesLocalDaemon(Account account)=>account.UsesCodexDesktop&&active.Contains(account.Id)&&HasSocket(account);
    public bool IsActive(Account account)=>account.UsesCodexDesktop&&(sessions.TryGetValue(account.Id,out var s)&&s.Ready&&s.Transport.IsRunning&&s.Client.IsConnected||UsesLocalDaemon(account));
    public async Task DiscoverAsync(Account account,bool force=false){
        if(!account.UsesCodexDesktop||Suspended)return;
        if(sessions.TryGetValue(account.Id,out var session)){
            if(session.Ready&&session.Transport.IsRunning&&session.Client.IsConnected)return;
            sessions.Remove(account.Id);await session.Client.DisposeAsync();
        }
        if(!HasSocket(account)){active.Remove(account.Id);return;}
        if(!force&&probes.TryGetValue(account.Id,out var last)&&DateTimeOffset.UtcNow-last<TimeSpan.FromSeconds(10))return;
        probes[account.Id]=DateTimeOffset.UtcNow;repository.ValidateOwned(repository.QuotaHome(account),account.Id);
        try{await using var client=await SocketClientAsync(account);if(!Suspended)active.Add(account.Id);}catch{active.Remove(account.Id);}
    }
    public async Task StartAsync(Account account,CancellationToken ct=default){
        if(!account.UsesCodexDesktop)throw new AppError("Quota is not available for this agent.");
        ct.ThrowIfCancellationRequested();await DiscoverAsync(account,true);
        if(IsActive(account)){if(!SharedWorkspace.BindingMatches(account,repository,preferences))throw new AppError("Close this profile and disable workspace sharing before choosing another workspace.");return;}
        repository.PrepareQuota(account);repository.PrepareProfile(account);NativePlatform.ProtectDirectory(repository.QuotaHome(account));NativePlatform.ProtectDirectory(repository.ProfilePath(account));
        await SharedWorkspace.PrepareAsync(account,repository,preferences);ct.ThrowIfCancellationRequested();
        // Keep the native RPC process ourselves. This works without the Desktop daemon command or Task Scheduler.
        var info=await StdioInfoAsync(account);ct.ThrowIfCancellationRequested();
        var transport=new StdioTransport(info);var session=new Session(transport,new RpcClient(transport));sessions.Add(account.Id,session);
        try{await session.Client.StartAsync(ct);ct.ThrowIfCancellationRequested();session.Ready=true;}
        catch{sessions.Remove(account.Id);await session.Client.DisposeAsync();throw;}
    }
    async Task<RpcClient> SocketClientAsync(Account account){
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var transport=await LocalSocketTransport.ConnectAsync(SocketPath(account),timeout.Token);var client=new RpcClient(transport);
        try{await client.StartAsync(timeout.Token);return client;}catch{await client.DisposeAsync();throw;}
    }
    async Task<ProcessStartInfo> StdioInfoAsync(Account account){
        repository.PrepareQuota(account);NativePlatform.ProtectDirectory(repository.QuotaHome(account));
        var cli=await platform.FindExecutableAsync("codex")??throw new AppError("A runnable Codex CLI was not found. Open ChatGPT from the Windows Start menu once, then try again. You can also choose an installed Codex CLI in Settings.");
        return ChildEnvironment.StartInfo(cli,new[]{"app-server","--listen","stdio://","-c","cli_auth_credentials_store=\"file\"","-c","analytics.enabled=false"},EnvironmentFor(account),repository.QuotaHome(account));
    }
    public async Task<RpcClient> StdioClientAsync(Account account,CancellationToken ct=default){
        var client=new RpcClient(new StdioTransport(await StdioInfoAsync(account)));
        try{await client.StartAsync(ct);return client;}catch{await client.DisposeAsync();throw;}
    }
    public async Task<Connection> ReadAsync(Account account,CancellationToken ct=default){
        if(!account.Agent.HasQuota())throw new AppError("Quota is not available for this agent.");
        if(account.UsesCodexDesktop){
            if(!IsActive(account)&&platform.Owned(account)==null)await StartAsync(account,ct);
            if(sessions.TryGetValue(account.Id,out var session)&&session.Ready&&session.Transport.IsRunning&&session.Client.IsConnected)return await session.Client.ReadQuotaAsync(ct);
            if(UsesLocalDaemon(account)){
                try{await using var local=await SocketClientAsync(account);return await local.ReadQuotaAsync(ct);}
                catch(AppError error) when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){}
            }
        }
        await using var fallback=await StdioClientAsync(account,ct);return await fallback.ReadQuotaAsync(ct);
    }
    public async Task StopAsync(Account account,CancellationToken ct=default){
        if(!account.UsesCodexDesktop)return;
        if(sessions.Remove(account.Id,out var session))await session.Client.DisposeAsync();
        repository.ValidateOwned(repository.QuotaHome(account),account.Id);
        if(!Directory.Exists(repository.QuotaHome(account)))return;
        if(UsesLocalDaemon(account)){await CommandAsync(account,"stop",ct);active.Remove(account.Id);}
        SharedWorkspace.Archive(account,repository);
    }
    public async Task ShutdownAsync(){Suspended=true;foreach(var id in new List<Guid>(sessions.Keys))if(sessions.Remove(id,out var session))await session.Client.DisposeAsync();}
    Dictionary<string,string> EnvironmentFor(Account account){var env=ChildEnvironment.Create(NativePlatform.EnvironmentValues(),repository.QuotaHome(account));if(account.UsesCodexDesktop&&account.SharesLocalWorkspace)env["CODEX_SQLITE_HOME"]=SharedWorkspace.BoundDatabase(account,repository,preferences);return env;}
    async Task CommandAsync(Account account,string action,CancellationToken ct=default){
        var cli=await platform.FindExecutableAsync("codex")??throw new AppError("A runnable Codex CLI was not found. Open ChatGPT from the Windows Start menu once, then try again. You can also choose an installed Codex CLI in Settings.");
        var info=ChildEnvironment.StartInfo(cli,new[]{"app-server","daemon",action,"-c","cli_auth_credentials_store=\"file\"","-c","analytics.enabled=false"},EnvironmentFor(account),repository.QuotaHome(account));
        info.RedirectStandardOutput=true;info.RedirectStandardError=true;using var child=Process.Start(info)??throw new AppError("Could not start the profile backend.");
        var output=child.StandardOutput.ReadToEndAsync();var error=child.StandardError.ReadToEndAsync();
        try{await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(90),ct);}catch(TimeoutException){if(!child.HasExited)child.Kill(true);throw new AppError("The Desktop backend did not start within 90 seconds. Try again.");}
        catch(OperationCanceledException){if(!child.HasExited){child.Kill(true);await child.WaitForExitAsync();}throw;}
        ct.ThrowIfCancellationRequested();var stdout=await output;var stderr=await error;if(child.ExitCode!=0){FixtureDiagnostic?.Invoke(action+" exited "+child.ExitCode+"\n"+stdout+"\n"+stderr);throw new AppError("The Desktop backend command failed. Update the app or check its executable in Settings.");}
    }
}
