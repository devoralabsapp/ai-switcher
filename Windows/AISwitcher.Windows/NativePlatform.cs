using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;

internal sealed record OwnedProcess(int Id,string Executable,string[] Arguments,bool HasWindow,long Created,int ParentId=0);
internal sealed partial class NativePlatform {
    readonly Repository repository;readonly Preferences preferences;
    List<OwnedProcess> processes=[];
    readonly Dictionary<Guid,Dictionary<(int,long),OwnedProcess>> tracked=[];
    readonly Dictionary<string,string?> discovered=[];
    public IReadOnlyList<OwnedProcess> Processes=>processes;
    public HashSet<Guid> PreparingRuntime { get; }=[];
    public event Action? PreparationChanged;
    internal Action<int>? FixtureStarted { get; set; }
    public NativePlatform(Repository repository,Preferences preferences){this.repository=repository;this.preferences=preferences;}
    public static Dictionary<string,string> EnvironmentValues()=>Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>().ToDictionary(x=>(string)x.Key,x=>(string)x.Value!,StringComparer.OrdinalIgnoreCase);
    public static bool IsElevated()=>new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    public static void ProtectDirectory(string path){
        Repository.RejectLinks(path);Directory.CreateDirectory(path);
        var sid=WindowsIdentity.GetCurrent().User??throw new AppError("Profile storage could not be verified.");
        var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);acl.SetOwner(sid);
        acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(acl);
    }
    public void InvalidateDiscovery()=>discovered.Clear();
    public async Task RefreshProcessesAsync(){
        processes=await Task.Run(()=>{
            List<OwnedProcess> result=[];
            using var searcher=new ManagementObjectSearcher("SELECT ProcessId, ParentProcessId, ExecutablePath, CommandLine, CreationDate FROM Win32_Process");
            foreach(ManagementObject value in searcher.Get())using(value){
                var args=value["CommandLine"] as string;
                var pid=Convert.ToInt32(value["ProcessId"]);
                try{using var process=Process.GetProcessById(pid);var exe=value["ExecutablePath"] as string??process.MainModule?.FileName;if(exe!=null){var created=process.StartTime.ToUniversalTime().ToFileTimeUtc();if(value["CreationDate"] is not string timestamp||ManagementDateTimeConverter.ToDateTime(timestamp).ToUniversalTime().ToFileTimeUtc()/10!=created/10)continue;result.Add(new(pid,exe,args==null?[]:SplitArguments(args),process.MainWindowHandle!=IntPtr.Zero,created,Convert.ToInt32(value["ParentProcessId"])));}}catch(ArgumentException){}catch(InvalidOperationException){}catch(System.ComponentModel.Win32Exception){}
            }
            return result;
        });
    }
    public OwnedProcess? Owned(Account account){var path=repository.DataPath(account);
        var owned=processes.FirstOrDefault(p=>p.Arguments.Contains("--user-data-dir="+path,StringComparer.OrdinalIgnoreCase)&&!p.Arguments.Any(x=>x.StartsWith("--type=",StringComparison.OrdinalIgnoreCase))&&IsAgentExecutable(account,p.Executable));
        foreach(var scoped in processes.Where(p=>p.Arguments.Contains("--user-data-dir="+path,StringComparer.OrdinalIgnoreCase)&&IsAgentExecutable(account,p.Executable))){if(!tracked.TryGetValue(account.Id,out var family))tracked[account.Id]=family=[];family[(scoped.Id,scoped.Created)]=scoped;}
        TrackChildren(account.Id);return owned;
    }
    void TrackChildren(Guid id){
        if(!tracked.TryGetValue(id,out var family))return;
        bool added;
        do{added=false;foreach(var child in processes){
            if(child.Id==Environment.ProcessId||family.ContainsKey((child.Id,child.Created)))continue;
            // Match a verified live parent or a recorded, bounded lifetime; never PID alone.
            if(processes.Any(parent=>parent.Id==child.ParentId&&parent.Created<=child.Created&&family.ContainsKey((parent.Id,parent.Created)))||exitedParents.Any(parent=>parent.Key.Id==child.ParentId&&family.ContainsKey(parent.Key)&&parent.Key.Created<=child.Created&&child.Created<=parent.Value)){family[(child.Id,child.Created)]=child;added=true;}
        }}while(added);
    }
    public async Task ForceStopAsync(Account account){
        if(account.Agent.IsShared())return;
        await FindExecutableAsync(ExecutableKey(account));
        for(var pass=0;pass<3;pass++){
            await RefreshProcessesAsync();Owned(account);
            if(!tracked.TryGetValue(account.Id,out var family))return;
            if(!Directory.Exists(repository.ProfilePath(account)))throw new AppError("Profile storage could not be verified.");
            repository.ValidateOwned(repository.ProfilePath(account),account.Id);
            foreach(var target in family.Values.OrderByDescending(p=>p.Created).ToArray()){
                if(target.Id==Environment.ProcessId)continue;
                var current=processes.FirstOrDefault(p=>p.Id==target.Id&&p.Created==target.Created&&SamePath(p.Executable,target.Executable));
                if(current==null)continue;
                try{using var process=Process.GetProcessById(target.Id);
                    if(process.HasExited||process.StartTime.ToUniversalTime().ToFileTimeUtc()!=target.Created)continue;
                    // Kill individual verified processes, never an unverified PID tree or every process with the same name.
                    process.Kill();await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
                }catch(ArgumentException){}catch(System.ComponentModel.Win32Exception)when(!StillSameProcess(target)){}
            }
        }
        await RefreshProcessesAsync();
        if(tracked.TryGetValue(account.Id,out var remaining)&&processes.Any(p=>remaining.ContainsKey((p.Id,p.Created))))throw new AppError("Some account processes could not be stopped. Check Session diagnostics and try again.");
        tracked.Remove(account.Id);
    }
    static bool StillSameProcess(OwnedProcess target){
        try{using var process=Process.GetProcessById(target.Id);return !process.HasExited&&process.StartTime.ToUniversalTime().ToFileTimeUtc()==target.Created;}
        catch(ArgumentException){return false;}catch(System.ComponentModel.Win32Exception){return true;}
    }
    bool IsAgentExecutable(Account account,string executable){
        if(account.EffectiveMode==LaunchMode.Desktop&&(account.Agent is Agent.Chatgpt or Agent.Claude)&&StoreRuntime.IsManagedExecutable(repository.Root,executable,account.Agent))return true;
        var expected=ExecutableKey(account);var configured=preferences.Executables.GetValueOrDefault(expected);
        if(!string.IsNullOrWhiteSpace(configured))return SamePath(executable,configured);
        return discovered.TryGetValue(expected,out var found)&&found!=null&&SamePath(executable,found);
    }
    public static bool SamePath(string a,string b)=>string.Equals(Path.GetFullPath(a),Path.GetFullPath(b),StringComparison.OrdinalIgnoreCase);
    public static string ExecutableKey(Account account)=>account.EffectiveMode==LaunchMode.Browser?account.Browser.ToString().ToLowerInvariant():account.Agent.Name().ToLowerInvariant();
    public async Task<string?> FindExecutableAsync(string key){
        if(key=="codex")return await FindCodexAsync();
        if(preferences.Executables.TryGetValue(key,out var configured)&&!string.IsNullOrWhiteSpace(configured))return File.Exists(configured)&&Path.GetExtension(configured).Equals(".exe",StringComparison.OrdinalIgnoreCase)?Path.GetFullPath(configured):null;
        if(discovered.TryGetValue(key,out var cached)&&cached!=null&&File.Exists(cached)&&!WindowsExecutable.IsStorePath(cached))return cached;
        var local=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);var pf=Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);var pf86=Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        List<string> candidates=key switch{
            "chrome"=>[Path.Combine(pf,"Google/Chrome/Application/chrome.exe"),Path.Combine(pf86,"Google/Chrome/Application/chrome.exe"),Path.Combine(local,"Google/Chrome/Application/chrome.exe")],
            "edge"=>[Path.Combine(pf86,"Microsoft/Edge/Application/msedge.exe"),Path.Combine(pf,"Microsoft/Edge/Application/msedge.exe")],
            "brave"=>[Path.Combine(pf,"BraveSoftware/Brave-Browser/Application/brave.exe"),Path.Combine(local,"BraveSoftware/Brave-Browser/Application/brave.exe")],
            "claude"=>[Path.Combine(local,"AnthropicClaude/Claude.exe"),Path.Combine(local,"Programs/Claude/Claude.exe"),Path.Combine(pf,"Claude/Claude.exe")],
            "antigravity"=>[Path.Combine(local,"Programs/Antigravity/Antigravity.exe"),Path.Combine(pf,"Antigravity/Antigravity.exe")],
            "chatgpt"=>[Path.Combine(local,"Programs/OpenAI/ChatGPT/ChatGPT.exe"),Path.Combine(local,"Programs/Codex/Codex.exe"),Path.Combine(pf,"ChatGPT/ChatGPT.exe")],
            "codex"=>[Path.Combine(local,"Programs/OpenAI/Codex/bin/codex.exe")],_=>[]};
        if(key is "claude" or "chatgpt"){
            // Only package metadata is queried; WindowsApps ACLs are not changed.
            var package=key=="claude"?"Claude":"OpenAI.Codex";
            foreach(var folder in await PackageLocationsAsync(package))foreach(var name in key=="claude"?new[]{"Claude.exe","app/Claude.exe"}:new[]{"app/ChatGPT.exe","app/Codex.exe","ChatGPT.exe","Codex.exe"})candidates.Add(Path.Combine(folder,name));
            if(key=="claude"){
                var baseDir=Path.Combine(local,"AnthropicClaude");if(Directory.Exists(baseDir))foreach(var version in Directory.EnumerateDirectories(baseDir,"app-*").OrderByDescending(x=>x))candidates.Add(Path.Combine(version,"Claude.exe"));
            }
        }
        return discovered[key]=candidates.FirstOrDefault(File.Exists);
    }
    async Task<string?> FindCodexAsync(){
        if(preferences.Executables.TryGetValue("codex",out var configured)&&!string.IsNullOrWhiteSpace(configured)){
            if(await CodexLocator.VerifyAsync(configured))return Path.GetFullPath(configured);
            return null;
        }
        if(discovered.TryGetValue("codex",out var cached)&&cached!=null&&File.Exists(cached))return cached;
        var local=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);var roaming=Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var candidates=CodexLocator.UserCandidates(local,roaming).ToList();
        var desktop=await FindExecutableAsync("chatgpt");if(desktop!=null&&!WindowsExecutable.IsStorePath(desktop)){var folder=Path.GetDirectoryName(desktop)!;foreach(var relative in new[]{"resources/codex.exe","resources/codex-cli/codex.exe","resources/codex-cli/bin/codex.exe"})candidates.Add(Path.Combine(folder,relative));}
        foreach(var folder in (Environment.GetEnvironmentVariable("PATH")??"").Split(Path.PathSeparator))if(!string.IsNullOrWhiteSpace(folder))candidates.Add(Path.Combine(folder.Trim('"'),"codex.exe"));
        return discovered["codex"]=await CodexLocator.ResolveAsync(candidates);
    }
    static async Task<IReadOnlyList<string>> PackageLocationsAsync(string package){
        var info=new ProcessStartInfo("powershell.exe"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
        foreach(var arg in new[]{"-NoProfile","-NonInteractive","-Command","Get-AppxPackage -Name $env:AISW_PACKAGE | Where-Object { ($_.Name -eq 'OpenAI.Codex' -and $_.PublisherId -eq '2p2nqsd0c76g0') -or ($_.Name -eq 'Claude' -and $_.PublisherId -eq 'pzs8sxrjxfjjc') } | Select-Object -ExpandProperty InstallLocation"})info.ArgumentList.Add(arg);info.Environment["AISW_PACKAGE"]=package;
        using var child=Process.Start(info);if(child==null)return [];
        var output=child.StandardOutput.ReadToEndAsync();var error=child.StandardError.ReadToEndAsync();
        try{await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));await error;return (await output).Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries).Where(Directory.Exists).ToArray();}
        catch(TimeoutException){child.Kill(true);return [];}
    }
    public static void VerifyIsolation(string executable,Agent agent){
        if(agent is not (Agent.Chatgpt or Agent.Claude))return;
        var archive=Path.Combine(Path.GetDirectoryName(executable)!,"resources","app.asar");
        if(!File.Exists(archive))throw new AppError("The installed Desktop app does not expose the required profile isolation mechanisms.");
        var bytes=File.ReadAllBytes(archive);var terms=agent==Agent.Chatgpt?new[]{"CODEX_ELECTRON_USER_DATA_PATH","CODEX_APP_SERVER_USE_LOCAL_DAEMON"}:new[]{"user-data-dir","requestSingleInstanceLock"};
        if(terms.Any(term=>bytes.AsSpan().IndexOf(Encoding.ASCII.GetBytes(term))<0))throw new AppError("The installed Desktop app does not expose the required profile isolation mechanisms.");
    }
    public async Task OpenAsync(Account account,Uri? url=null,bool useLocalDaemon=true,CancellationToken ct=default){
        var exe=await FindExecutableAsync(ExecutableKey(account))??throw new AppError("The required app or browser was not found. Choose its executable in Settings.");
        ct.ThrowIfCancellationRequested();
        if(account.Agent.IsShared()) { Process.Start(new ProcessStartInfo(exe){UseShellExecute=true});return; }
        await RefreshProcessesAsync();var owned=Owned(account);
        if(url==null&&owned?.HasWindow==true){Activate(owned.Id);return;}
        if(account.EffectiveMode==LaunchMode.Desktop)VerifyIsolation(exe,account.Agent);
        if(account.EffectiveMode==LaunchMode.Desktop&&(account.Agent is Agent.Chatgpt or Agent.Claude)&&WindowsExecutable.IsStorePath(exe)){
            var installed=await PackageLocationsAsync(account.Agent==Agent.Claude?"Claude":"OpenAI.Codex");
            if(!installed.Any(location=>SamePath(Path.GetDirectoryName(exe)!,Path.Combine(location,"app"))||SamePath(Path.GetDirectoryName(exe)!,location)))throw new AppError(account.Agent==Agent.Claude?"The Claude Store installation could not be verified. Reset its path in Settings and try again.":"The ChatGPT Store installation could not be verified. Reset its path in Settings and try again.");
            PreparingRuntime.Add(account.Id);PreparationChanged?.Invoke();
            try{var source=exe;exe=await Task.Run(()=>StoreRuntime.PrepareAsync(repository.Root,source,ct));}catch(Exception error)when(error is IOException or UnauthorizedAccessException){throw new AppError(account.Agent==Agent.Claude?"Windows could not prepare the Claude Store runtime. The installed app and account data were preserved. Check Session diagnostics and try again.":"Windows could not prepare the ChatGPT Store runtime. The installed app and account data were preserved. Check Session diagnostics and try again.");}finally{PreparingRuntime.Remove(account.Id);PreparationChanged?.Invoke();}
        }
        repository.PrepareProfile(account);ProtectDirectory(repository.ProfilePath(account));
        var env=ChildEnvironment.Create(EnvironmentValues(),account.UsesCodexDesktop?repository.QuotaHome(account):null);
        if(account.UsesCodexDesktop){env["CODEX_ELECTRON_USER_DATA_PATH"]=repository.DataPath(account);if(useLocalDaemon)env["CODEX_APP_SERVER_USE_LOCAL_DAEMON"]="1";if(account.SharesLocalWorkspace)env["CODEX_SQLITE_HOME"]=SharedWorkspace.Database(preferences);}
        if(account.UsesCodexDesktop){try{var cli=await FindExecutableAsync("codex");if(cli!=null)env["CODEX_CLI_PATH"]=cli;}catch(AppError){/* The Desktop app can use its own packaged CLI while the selected external CLI is unavailable. */}}
        if(account.Agent==Agent.Claude&&account.EffectiveMode==LaunchMode.Desktop)env["CLAUDE_CONFIG_DIR"]=repository.CodeConfig(account);
        var arguments=new List<string>{"--user-data-dir="+repository.DataPath(account)};
        if(account.EffectiveMode==LaunchMode.Browser)arguments.AddRange(["--no-first-run","--no-default-browser-check","--disable-background-mode","--app="+(url??account.Agent.Url()).AbsoluteUri]);
        ct.ThrowIfCancellationRequested();
        using var child=Process.Start(ChildEnvironment.StartInfo(exe,arguments,env,repository.ProfilePath(account)))??throw new AppError("Could not open the AI agent window. Try again or check the browser.");
        FixtureStarted?.Invoke(child.Id);
        for(var i=0;i<120;i++){
            await Task.Delay(250,ct);await RefreshProcessesAsync();var running=Owned(account);if(running?.HasWindow==true){Activate(running.Id);return;}
            if(child.HasExited&&child.ExitCode!=0)break;
        }
        throw new AppError("Could not open the AI agent window. Try again or check the browser.");
    }
    public async Task CloseAsync(Account account){
        if(account.Agent.IsShared())return;await FindExecutableAsync(ExecutableKey(account));await RefreshProcessesAsync();var owned=Owned(account);
        repository.ValidateOwned(repository.ProfilePath(account),account.Id);
        if(owned!=null){
            Process? process=null;try{process=Process.GetProcessById(owned.Id);}catch(ArgumentException){}
            if(process!=null)using(process){
                if(process.StartTime.ToUniversalTime().ToFileTimeUtc()!=owned.Created)throw new AppError("The session process changed. Check its status before closing again.");
                if(!process.HasExited){
                    if(account.EffectiveMode==LaunchMode.Desktop&&(account.Agent is Agent.Chatgpt or Agent.Claude)){
                        try{await ProfileQuit.RequestAsync(owned.Id,owned.Created);}catch(AppError)when(process.HasExited){}
                    }else if(!process.CloseMainWindow())throw new AppError("This profile is still running. Save drafts and close its window before trying again.");
                    try{await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));}catch(TimeoutException){throw new AppError("This profile did not agree to quit. Finish any confirmation in its window or use its own tray Quit action, then retry.");}
                }
                // A helper created while the root was quitting may appear only after
                // its parent has exited. Keep the exact parent's lifetime, not just PID.
                exitedParents[(owned.Id,owned.Created)]=process.ExitTime.ToUniversalTime().ToFileTimeUtc();
            }
        }
        await CompleteCloseAsync(account);
    }
    static void Activate(int pid){using var process=Process.GetProcessById(pid);var window=process.MainWindowHandle;if(window!=IntPtr.Zero){ShowWindow(window,9);SetForegroundWindow(window);}}
    public static string[] SplitArguments(string command){var ptr=CommandLineToArgvW(command,out var count);if(ptr==IntPtr.Zero)return [];try{return Enumerable.Range(0,count).Select(i=>Marshal.PtrToStringUni(Marshal.ReadIntPtr(ptr,i*IntPtr.Size))??"").ToArray();}finally{LocalFree(ptr);}}
    [DllImport("shell32.dll",SetLastError=true)]static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)]string command,out int argc);
    [DllImport("kernel32.dll")]static extern IntPtr LocalFree(IntPtr ptr);
    [DllImport("user32.dll")]static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]static extern bool ShowWindow(IntPtr window,int command);
}
