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
    readonly HashSet<Guid> active=[];
    public BackendService(Repository repository,NativePlatform platform,Preferences preferences){this.repository=repository;this.platform=platform;this.preferences=preferences;}
    public string SocketPath(Account account)=>Path.Combine(repository.QuotaHome(account),"app-server-control","app-server-control.sock");
    public bool HasSocket(Account account)=>account.UsesCodexDesktop&&File.Exists(SocketPath(account));
    public bool IsActive(Account account)=>account.UsesCodexDesktop&&active.Contains(account.Id)&&File.Exists(SocketPath(account));
    public async Task DiscoverAsync(Account account){if(!account.UsesCodexDesktop||!File.Exists(SocketPath(account)))return;repository.ValidateOwned(repository.QuotaHome(account),account.Id);try{await using var client=await SocketClientAsync(account);active.Add(account.Id);}catch{active.Remove(account.Id);}}
    public async Task StartAsync(Account account){
        if(!account.UsesCodexDesktop)throw new AppError("Quota is not available for this agent.");
        if(NativePlatform.IsElevated())throw new AppError("Run AI Switcher without administrator privileges to connect background sessions.");
        repository.PrepareQuota(account);repository.PrepareProfile(account);NativePlatform.ProtectDirectory(repository.QuotaHome(account));NativePlatform.ProtectDirectory(repository.ProfilePath(account));
        if(Encoding.UTF8.GetByteCount(SocketPath(account))>=104)throw new AppError("The Desktop backend path is too long for a local socket. Use a shorter Windows user-profile path.");
        if(IsActive(account)){if(!SharedWorkspace.BindingMatches(account,repository,preferences))throw new AppError("Close this profile and disable workspace sharing before choosing another workspace.");return;}
        await SharedWorkspace.PrepareAsync(account,repository,preferences);
        await CommandAsync(account,"start");
        for(var i=0;i<40;i++){
            try{await using var client=await SocketClientAsync(account);active.Add(account.Id);return;}catch(Exception error){FixtureDiagnostic?.Invoke("Local connection: "+error.GetType().Name+": "+error.Message);await Task.Delay(250);}
        }
        throw new AppError("Could not connect to this Desktop profile's backend. Try opening it again or update ChatGPT Desktop.");
    }
    async Task<RpcClient> SocketClientAsync(Account account){
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var transport=await LocalSocketTransport.ConnectAsync(SocketPath(account),timeout.Token);var client=new RpcClient(transport);
        try{await client.StartAsync(timeout.Token);return client;}catch{await client.DisposeAsync();throw;}
    }
    public async Task<RpcClient> StdioClientAsync(Account account,CancellationToken ct=default){
        repository.PrepareQuota(account);NativePlatform.ProtectDirectory(repository.QuotaHome(account));
        var cli=await platform.FindExecutableAsync("codex")??throw new AppError("A runnable Codex CLI was not found. Open ChatGPT from the Windows Start menu once, then try again. You can also choose an installed Codex CLI in Settings.");
        var env=EnvironmentFor(account);
        var info=ChildEnvironment.StartInfo(cli,new[]{"app-server","--listen","stdio://","-c","cli_auth_credentials_store=\"file\"","-c","analytics.enabled=false"},env,repository.QuotaHome(account));
        var client=new RpcClient(new StdioTransport(info));try{await client.StartAsync(ct);return client;}catch{await client.DisposeAsync();throw;}
    }
    public async Task<Connection> ReadAsync(Account account,CancellationToken ct=default){
        if(!account.Agent.HasQuota())throw new AppError("Quota is not available for this agent.");
        if(account.UsesCodexDesktop){
            if(!IsActive(account)&&platform.Owned(account)==null)await StartAsync(account);
            try{if(!IsActive(account))throw new AppError("The Codex session is signed out or expired. Reconnect the account.");await using var local=await SocketClientAsync(account);return await local.ReadQuotaAsync(ct);}
            catch(AppError error) when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){}
        }
        await using var fallback=await StdioClientAsync(account,ct);return await fallback.ReadQuotaAsync(ct);
    }
    public async Task StopAsync(Account account){if(!account.UsesCodexDesktop)return;repository.ValidateOwned(repository.QuotaHome(account),account.Id);if(!Directory.Exists(repository.QuotaHome(account)))return;if(!IsActive(account)&&!HasSocket(account)){SharedWorkspace.Archive(account,repository);return;}await CommandAsync(account,"stop");active.Remove(account.Id);SharedWorkspace.Archive(account,repository);}
    Dictionary<string,string> EnvironmentFor(Account account){var env=ChildEnvironment.Create(NativePlatform.EnvironmentValues(),repository.QuotaHome(account));if(account.UsesCodexDesktop&&account.SharesLocalWorkspace)env["CODEX_SQLITE_HOME"]=SharedWorkspace.BoundDatabase(account,repository,preferences);return env;}
    async Task CommandAsync(Account account,string action){
        var cli=await platform.FindExecutableAsync("codex")??throw new AppError("A runnable Codex CLI was not found. Open ChatGPT from the Windows Start menu once, then try again. You can also choose an installed Codex CLI in Settings.");
        var info=ChildEnvironment.StartInfo(cli,new[]{"app-server","daemon",action,"-c","cli_auth_credentials_store=\"file\"","-c","analytics.enabled=false"},EnvironmentFor(account),repository.QuotaHome(account));
        info.RedirectStandardOutput=true;info.RedirectStandardError=true;using var child=Process.Start(info)??throw new AppError("Could not start the profile backend.");
        var output=child.StandardOutput.ReadToEndAsync();var error=child.StandardError.ReadToEndAsync();
        try{await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(90));}catch(TimeoutException){if(!child.HasExited)child.Kill(true);throw new AppError("The Desktop backend did not start within 90 seconds. Try again.");}
        var stdout=await output;var stderr=await error;if(child.ExitCode!=0){FixtureDiagnostic?.Invoke(action+" exited "+child.ExitCode+"\n"+stdout+"\n"+stderr);throw new AppError("The Desktop backend command failed. Update the app or check its executable in Settings.");}
    }
}
