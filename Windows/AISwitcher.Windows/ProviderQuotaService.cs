using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal sealed class ProviderQuotaService {
    readonly Repository repo;readonly Preferences preferences;
    readonly Dictionary<Guid,List<Process>> commands=[];
    public HashSet<Guid> Connected { get; }=[];
    public ProviderQuotaService(Repository repository,Preferences prefs){repo=repository;preferences=prefs;}
    public static string Key(Agent agent)=>agent==Agent.Claude?"claudeCode":"antigravityCli";
    public string Executable(Agent agent){
        if(preferences.Executables.TryGetValue(Key(agent),out var configured)&&File.Exists(configured)&&Path.GetExtension(configured).Equals(".exe",StringComparison.OrdinalIgnoreCase)&&WindowsExecutable.IsConsole(configured))return configured;
        var home=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);var local=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);var roaming=Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var name=agent==Agent.Claude?"claude.exe":"agy.exe";List<string> paths=[Path.Combine(home,".local","bin",name),Path.Combine(local,"agy","bin",name),Path.Combine(local,"agy","bin","antigravity.exe")];
        foreach(var directory in (Environment.GetEnvironmentVariable("PATH")??"").Split(Path.PathSeparator))if(!string.IsNullOrWhiteSpace(directory)){paths.Add(Path.Combine(directory.Trim('"'),name));if(agent==Agent.Antigravity)paths.Add(Path.Combine(directory.Trim('"'),"antigravity.exe"));}
        if(agent==Agent.Claude){
            foreach(var folder in new[]{Path.Combine(roaming,"npm","node_modules","@anthropic-ai"),Path.Combine(local,"Claude","claude-code"),Path.Combine(local,"AnthropicClaude","claude-code")}){
                if(Directory.Exists(folder))try{paths.AddRange(Directory.EnumerateFiles(folder,"claude.exe",SearchOption.AllDirectories).Take(1000).OrderByDescending(x=>x));}catch(UnauthorizedAccessException){}
            }
        }
        return paths.FirstOrDefault(path=>File.Exists(path)&&WindowsExecutable.IsConsole(path))??throw new AppError("Install Claude Code or Antigravity CLI, or select its executable in quota settings.");
    }
    string Config(Account a)=>repo.CodeConfig(a with{LaunchMode=LaunchMode.Desktop});
    Dictionary<string,string> EnvironmentFor(Account a){
        if(a.UsesPrivateAntigravity){repo.PrepareProfile(a);AntigravityProfile.Validate(repo,a);foreach(var dir in AntigravityProfile.Directories(repo,a))NativePlatform.ProtectDirectory(dir);return AntigravityProfile.Environment(NativePlatform.EnvironmentValues(),repo,a);}
        var env=ChildEnvironment.Create(NativePlatform.EnvironmentValues());
        if(a.Agent==Agent.Claude){var desktop=a with{LaunchMode=LaunchMode.Desktop};repo.PrepareProfile(desktop);NativePlatform.ProtectDirectory(repo.ProfilePath(desktop));env["CLAUDE_CONFIG_DIR"]=Config(a);}
        return env;
    }
    Process Start(Account a,string executable,IEnumerable<string> args,Action<string>? diagnostic=null){
        if(a.UsesPrivateAntigravity&&!AntigravityProfile.SupportsPrivateStorage(executable))throw new AppError(AntigravityProfile.Unsupported);
        var info=ChildEnvironment.StartInfo(executable,args,EnvironmentFor(a),a.UsesPrivateAntigravity?AntigravityProfile.Home(repo,a):repo.Root);info.RedirectStandardInput=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
        if(a.Agent==Agent.Antigravity&&args.SequenceEqual(ProviderQuota.AntigravityArguments))info.Environment["CI"]="true";
        var process=new Process{StartInfo=info};process.ErrorDataReceived+=(_,e)=>{if(e.Data!=null)diagnostic?.Invoke(e.Data);};
        if(!process.Start())throw new AppError(ProviderQuota.Invalid);process.BeginErrorReadLine();
        if(!commands.TryGetValue(a.Id,out var children))commands[a.Id]=children=[];children.Add(process);return process;
    }
    static async Task StopProcess(Process process){try{if(!process.HasExited){process.Kill(true);await process.WaitForExitAsync();}}catch(InvalidOperationException){}finally{process.Dispose();}}
    async Task<string> Run(Account a,string executable,string[] args,CancellationToken ct){
        if(a.Agent==Agent.Antigravity&&args.SequenceEqual(ProviderQuota.AntigravityArguments))return await RunDetachedQuota(a,executable,args,ct);
        var signOut=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var detect=a.Agent==Agent.Antigravity&&args.SequenceEqual(ProviderQuota.AntigravityArguments);
        var process=Start(a,executable,args,line=>{if(detect&&ProviderQuota.AntigravityRequiresSignIn(line))signOut.TrySetResult();});
        try{
            process.StandardInput.Close();var data=new StringBuilder();var buffer=new char[4096];int count;
            async Task<string> Collect(){
                while((count=await process.StandardOutput.ReadAsync(buffer,ct))>0){if(data.Length+count>1048576)throw new AppError(ProviderQuota.Invalid);data.Append(buffer,0,count);}
                await process.WaitForExitAsync(ct);return data.ToString();
            }
            var collect=Collect();
            if(await Task.WhenAny(collect,signOut.Task)==signOut.Task){
                ct.ThrowIfCancellationRequested();await StopBeforeDrain();try{await collect;}catch(IOException){}catch(OperationCanceledException){}throw new AppError(ProviderQuota.SignedOut);
            }
            var text=await collect;if(detect&&ProviderQuota.AntigravityRequiresSignIn(text))throw new AppError(ProviderQuota.SignedOut);return text;
            async Task StopBeforeDrain(){if(!process.HasExited){process.Kill(true);await process.WaitForExitAsync();}}
        }finally{commands[a.Id].Remove(process);await StopProcess(process);}
    }
    async Task<string> RunDetachedQuota(Account account,string executable,string[] arguments,CancellationToken ct){
        if(account.UsesPrivateAntigravity&&!AntigravityProfile.SupportsPrivateStorage(executable))throw new AppError(AntigravityProfile.Unsupported);
        var info=ChildEnvironment.StartInfo(executable,arguments,EnvironmentFor(account),account.UsesPrivateAntigravity?AntigravityProfile.Home(repo,account):repo.Root);
        await using var command=DetachedCommand.Start(info);if(!commands.TryGetValue(account.Id,out var owned))commands[account.Id]=owned=[];owned.Add(command.Process);
        try{
            command.Input.Close();
            async Task<string> Read(System.IO.StreamReader reader,bool error){
                var result=new StringBuilder();var buffer=new char[4096];int count;
                while((count=await reader.ReadAsync(buffer,ct))>0){if(result.Length+count>1048576)throw new AppError(ProviderQuota.Invalid);result.Append(buffer,0,count);if(error&&ProviderQuota.AntigravityRequiresSignIn(result.ToString()))throw new AppError(ProviderQuota.SignedOut);}
                return result.ToString();
            }
            var output=Read(command.Output,false);var diagnostic=Read(command.Error,true);
            // Observe either pipe's failure before waiting for an interactive OAuth
            // timeout. Raw diagnostics are never persisted or shown to the user.
            var first=await Task.WhenAny(output,diagnostic);await first;
            var text=await output;_=await diagnostic;await command.Process.WaitForExitAsync(ct);
            if(ProviderQuota.AntigravityRequiresSignIn(text))throw new AppError(ProviderQuota.SignedOut);return text;
        }finally{owned.Remove(command.Process);}
    }
    async Task<JsonElement> Control(Process process,string subtype,CancellationToken ct){
        var id=Guid.NewGuid().ToString("N");
        await process.StandardInput.WriteLineAsync(ProviderQuota.ControlRequest(id,subtype));await process.StandardInput.FlushAsync(ct);
        for(var i=0;i<64;i++){
            var line=await process.StandardOutput.ReadLineAsync(ct);if(line==null||line.Length>1048576)throw new AppError(ProviderQuota.Invalid);
            using var doc=JsonDocument.Parse(line);var root=doc.RootElement;var response=ProviderQuota.Get(root,"response");
            if(ProviderQuota.Get(root,"type").GetString()!="control_response"||response.ValueKind!=JsonValueKind.Object||ProviderQuota.Get(response,"request_id").GetString()!=id)continue;
            if(ProviderQuota.Get(response,"subtype").GetString()!="success")throw new AppError(ProviderQuota.Outdated);
            return ProviderQuota.Get(response,"response").Clone();
        }
        throw new AppError(ProviderQuota.Invalid);
    }
    public bool HasExecutable(Agent agent){try{_ = Executable(agent);return true;}catch(AppError){return false;}}
    public async Task<string> VerifyInstalledAsync(Account account,CancellationToken ct){
        var executable=Executable(account.Agent);var version=await Run(account,executable,["--version"],ct);
        if(!ProviderQuota.Accepts(version,account.Agent))throw new AppError(ProviderQuota.Outdated);
        return executable;
    }
    public async Task<Connection> ReadAsync(Account account,CancellationToken ct){
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(ct);deadline.CancelAfter(TimeSpan.FromSeconds(45));ct=deadline.Token;
        var executable=Executable(account.Agent);var version=await Run(account,executable,["--version"],ct);
        if(!ProviderQuota.Accepts(version,account.Agent))throw new AppError(ProviderQuota.Outdated);
        if(account.Agent==Agent.Claude){
            async Task<Identity> Identity(){
                using var doc=JsonDocument.Parse(await Run(account,executable,["auth","status"],ct));var root=doc.RootElement;
                if(ProviderQuota.Get(root,"loggedIn").ValueKind!=JsonValueKind.True)throw new AppError(ProviderQuota.SignedOut);
                if(ProviderQuota.Get(root,"authMethod").GetString()!="claude.ai")throw new AppError(ProviderQuota.Unavailable);
                var email=ProviderQuota.Get(root,"email");var config=ProviderQuota.Get(root,"configDirectory");
                if(email.ValueKind!=JsonValueKind.String||string.IsNullOrWhiteSpace(email.GetString())||config.ValueKind!=JsonValueKind.String||!NativePlatform.SamePath(config.GetString()!,Config(account)))throw new AppError(ProviderQuota.Changed);
                if(account.EmailHint.Contains('@')&&!string.Equals(account.EmailHint,email.GetString(),StringComparison.OrdinalIgnoreCase))throw new AppError(ProviderQuota.Changed);
                return new(email.GetString(),null);
            }
            var before=await Identity();var process=Start(account,executable,ProviderQuota.ClaudeArguments);JsonElement usage;
            try{await Control(process,"initialize",ct);usage=await Control(process,"get_usage",ct);}
            finally{commands[account.Id].Remove(process);await StopProcess(process);}
            var after=await Identity();if(!before.Matches(after))throw new AppError(ProviderQuota.Changed);
            return ProviderQuota.Parse(usage,account.Agent,after);
        }
        string IdentityPath()=>account.UsesPrivateAntigravity?(File.Exists(AntigravityProfile.CliIdentity(repo,account))?AntigravityProfile.CliIdentity(repo,account):AntigravityProfile.DesktopIdentity(repo,account)):LegacyIdentityPath();
        string LegacyIdentityPath(){var home=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);var modern=Path.Combine(home,".gemini","antigravity-cli","antigravity-oauth-token");return File.Exists(modern)?modern:Path.Combine(home,".gemini","jetski-standalone-oauth-token");}
        var path=IdentityPath();var savedBefore=AntigravityProfile.ReadIdentity(path);if(account.UsesPrivateAntigravity&&savedBefore==null)throw new AppError(ProviderQuota.SignedOut);
        var text=await Run(account,executable,ProviderQuota.AntigravityArguments,ct);
        if(new[]{"not signed in","not logged in","please sign in","authentication required","login required"}.Any(term=>text.Contains(term,StringComparison.OrdinalIgnoreCase)))throw new AppError(ProviderQuota.SignedOut);
        using var result=JsonDocument.Parse(text);var savedAfter=AntigravityProfile.ReadIdentity(path);
        if(savedBefore!=savedAfter||savedAfter?.Email is {} email&&account.EmailHint.Contains('@')&&!string.Equals(account.EmailHint,email,StringComparison.OrdinalIgnoreCase))throw new AppError(ProviderQuota.Changed);
        if(account.UsesPrivateAntigravity&&AntigravityProfile.ReadIdentity(AntigravityProfile.DesktopIdentity(repo,account))?.Email is {} desktopEmail&&savedAfter?.Email is {} cliEmail&&!string.Equals(desktopEmail,cliEmail,StringComparison.OrdinalIgnoreCase))throw new AppError(ProviderQuota.Changed);
        return ProviderQuota.Parse(result.RootElement,account.Agent,savedAfter??new(null,null))with{IdentityFetchedAt=DateTimeOffset.UtcNow,ProviderSessionKind=account.UsesPrivateAntigravity?AntigravityProfile.CliSessionKind:null};
    }
    public async Task DisconnectAsync(Account account){
        Connected.Remove(account.Id);
        if(commands.TryGetValue(account.Id,out var children))foreach(var process in children.ToArray())try{if(!process.HasExited){process.Kill(true);await process.WaitForExitAsync();}}catch(InvalidOperationException){}
    }
    public async Task<Connection> SignInAsync(Account account,CancellationToken ct){
        var executable=Executable(account.Agent);if(account.UsesPrivateAntigravity&&!AntigravityProfile.SupportsPrivateStorage(executable))throw new AppError(AntigravityProfile.Unsupported);
        var env=EnvironmentFor(account);var script="& '"+executable.Replace("'","''")+"'"+(account.Agent==Agent.Claude?" auth login":"");
        var info=ChildEnvironment.StartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe"),new[]{"-NoProfile","-NoExit","-EncodedCommand",Convert.ToBase64String(Encoding.Unicode.GetBytes(script))},env,account.UsesPrivateAntigravity?Path.GetDirectoryName(executable)!:repo.Root);info.CreateNoWindow=false;
        var process=Process.Start(info)??throw new AppError(ProviderQuota.SignedOut);if(!commands.TryGetValue(account.Id,out var children))commands[account.Id]=children=[];children.Add(process);
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(ct);timeout.CancelAfter(TimeSpan.FromMinutes(10));
        try{
            while(!process.HasExited){
                await Task.Delay(2500,timeout.Token);
                try{return await ReadAsync(account,timeout.Token);}catch(AppError error)when(error.Key is ProviderQuota.SignedOut or ProviderQuota.Unavailable or ProviderQuota.Invalid){}
            }
            throw new AppError(ProviderQuota.SignedOut);
        }finally{children.Remove(process);await StopProcess(process);}
    }
    public void SignIn(Account account){
        var executable=Executable(account.Agent);_ = EnvironmentFor(account);
        static string Literal(string text)=>"'"+text.Replace("'","''")+"'";
        var script="$env:ANTHROPIC_AUTH_TOKEN=$null; $env:ANTHROPIC_BASE_URL=$null; $env:GOOGLE_APPLICATION_CREDENTIALS=$null; $env:AGY_ADC_AUTH=$null; $env:ANTHROPIC_API_KEY=$null; $env:CLAUDE_CODE_OAUTH_TOKEN=$null; $env:GEMINI_API_KEY=$null; $env:GOOGLE_API_KEY=$null; ";
        if(account.Agent==Agent.Claude)script+="$env:CLAUDE_CONFIG_DIR="+Literal(Config(account))+"; ";
        script+="& "+Literal(executable)+(account.Agent==Agent.Claude?" auth login":"");
        var info=new ProcessStartInfo("powershell.exe"){UseShellExecute=true};foreach(var argument in new[]{"-NoProfile","-NoExit","-EncodedCommand",Convert.ToBase64String(Encoding.Unicode.GetBytes(script))})info.ArgumentList.Add(argument);Process.Start(info);
    }
}
