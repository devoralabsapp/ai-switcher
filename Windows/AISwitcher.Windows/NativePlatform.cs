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

internal sealed record OwnedProcess(int Id,string Executable,string[] Arguments,bool HasWindow);
internal sealed class NativePlatform {
    readonly Repository repository;readonly Preferences preferences;
    List<OwnedProcess> processes=[];
    readonly Dictionary<string,string?> discovered=[];
    public IReadOnlyList<OwnedProcess> Processes=>processes;
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
            using var searcher=new ManagementObjectSearcher("SELECT ProcessId, ExecutablePath, CommandLine FROM Win32_Process WHERE Name='Claude.exe' OR Name='ChatGPT.exe' OR Name='Codex.exe' OR Name='chrome.exe' OR Name='msedge.exe' OR Name='brave.exe' OR Name='Antigravity.exe' OR Name='AISwitcher.exe'");
            foreach(ManagementObject value in searcher.Get())using(value){
                if(value["ExecutablePath"] is not string exe||value["CommandLine"] is not string args)continue;
                var pid=Convert.ToInt32(value["ProcessId"]);
                try{using var process=Process.GetProcessById(pid);result.Add(new(pid,exe,SplitArguments(args),process.MainWindowHandle!=IntPtr.Zero));}catch(ArgumentException){}
            }
            return result;
        });
    }
    public OwnedProcess? Owned(Account account){var path=repository.DataPath(account);
        return processes.FirstOrDefault(p=>p.Arguments.Contains("--user-data-dir="+path,StringComparer.OrdinalIgnoreCase)&&!p.Arguments.Any(x=>x.StartsWith("--type=",StringComparison.OrdinalIgnoreCase))&&IsAgentExecutable(account,p.Executable));}
    bool IsAgentExecutable(Account account,string executable){var expected=ExecutableKey(account);var configured=preferences.Executables.GetValueOrDefault(expected);
        if(!string.IsNullOrWhiteSpace(configured))return SamePath(executable,configured);
        return discovered.TryGetValue(expected,out var found)&&found!=null&&SamePath(executable,found);}
    public static bool SamePath(string a,string b)=>string.Equals(Path.GetFullPath(a),Path.GetFullPath(b),StringComparison.OrdinalIgnoreCase);
    public static string ExecutableKey(Account account)=>account.EffectiveMode==LaunchMode.Browser?account.Browser.ToString().ToLowerInvariant():account.Agent.Name().ToLowerInvariant();
    public async Task<string?> FindExecutableAsync(string key){
        if(preferences.Executables.TryGetValue(key,out var configured)&&!string.IsNullOrWhiteSpace(configured))return File.Exists(configured)&&Path.GetExtension(configured).Equals(".exe",StringComparison.OrdinalIgnoreCase)?Path.GetFullPath(configured):null;
        if(discovered.TryGetValue(key,out var cached))return cached;
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
            var package=key=="claude"?"*Claude*":"OpenAI.Codex";
            foreach(var folder in await PackageLocationsAsync(package))foreach(var name in key=="claude"?new[]{"Claude.exe","app/Claude.exe"}:new[]{"app/ChatGPT.exe","app/Codex.exe","ChatGPT.exe","Codex.exe"})candidates.Add(Path.Combine(folder,name));
            if(key=="claude"){
                var baseDir=Path.Combine(local,"AnthropicClaude");if(Directory.Exists(baseDir))foreach(var version in Directory.EnumerateDirectories(baseDir,"app-*").OrderByDescending(x=>x))candidates.Add(Path.Combine(version,"Claude.exe"));
            }
        }
        if(key=="codex"){
            var desktop=await FindExecutableAsync("chatgpt");if(desktop!=null){var folder=Path.GetDirectoryName(desktop)!;foreach(var relative in new[]{"resources/codex.exe","resources/codex-cli/codex.exe","resources/codex-cli/bin/codex.exe"})candidates.Add(Path.Combine(folder,relative));}
            foreach(var folder in (Environment.GetEnvironmentVariable("PATH")??"").Split(Path.PathSeparator))if(!string.IsNullOrWhiteSpace(folder))candidates.Add(Path.Combine(folder,"codex.exe"));
        }
        return discovered[key]=candidates.FirstOrDefault(File.Exists);
    }
    static async Task<IReadOnlyList<string>> PackageLocationsAsync(string package){
        var info=new ProcessStartInfo("powershell.exe"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
        foreach(var arg in new[]{"-NoProfile","-NonInteractive","-Command","Get-AppxPackage -Name $env:AISW_PACKAGE | Select-Object -ExpandProperty InstallLocation"})info.ArgumentList.Add(arg);info.Environment["AISW_PACKAGE"]=package;
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
    public async Task OpenAsync(Account account,Uri? url=null){
        var exe=await FindExecutableAsync(ExecutableKey(account))??throw new AppError("The required app or browser was not found. Choose its executable in Settings.");
        if(account.Agent.IsShared()) { Process.Start(new ProcessStartInfo(exe){UseShellExecute=true});return; }
        await RefreshProcessesAsync();var owned=Owned(account);
        if(url==null&&owned?.HasWindow==true){Activate(owned.Id);return;}
        if(account.EffectiveMode==LaunchMode.Desktop)VerifyIsolation(exe,account.Agent);
        repository.PrepareProfile(account);ProtectDirectory(repository.ProfilePath(account));
        var env=ChildEnvironment.Create(EnvironmentValues(),account.UsesCodexDesktop?repository.QuotaHome(account):null);
        if(account.UsesCodexDesktop){env["CODEX_ELECTRON_USER_DATA_PATH"]=repository.DataPath(account);env["CODEX_APP_SERVER_USE_LOCAL_DAEMON"]="1";if(account.SharesLocalWorkspace)env["CODEX_SQLITE_HOME"]=SharedWorkspace.Database(preferences);}
        if(account.Agent==Agent.Claude&&account.EffectiveMode==LaunchMode.Desktop)env["CLAUDE_CONFIG_DIR"]=repository.CodeConfig(account);
        var arguments=new List<string>{"--user-data-dir="+repository.DataPath(account)};
        if(account.EffectiveMode==LaunchMode.Browser)arguments.AddRange(["--no-first-run","--no-default-browser-check","--disable-background-mode","--app="+(url??account.Agent.Url()).AbsoluteUri]);
        using var child=Process.Start(ChildEnvironment.StartInfo(exe,arguments,env,repository.ProfilePath(account)))??throw new AppError("Could not open the AI agent window. Try again or check the browser.");
        for(var i=0;i<120;i++){
            await Task.Delay(250);await RefreshProcessesAsync();var running=Owned(account);if(running?.HasWindow==true){Activate(running.Id);return;}
            if(child.HasExited&&child.ExitCode!=0)break;
        }
        throw new AppError("Could not open the AI agent window. Try again or check the browser.");
    }
    public async Task CloseAsync(Account account){
        if(account.Agent.IsShared())return;await RefreshProcessesAsync();var owned=Owned(account);if(owned==null)return;
        repository.ValidateOwned(repository.ProfilePath(account),account.Id);
        using var process=Process.GetProcessById(owned.Id);
        if(!process.CloseMainWindow())throw new AppError("This profile is still running. Save drafts and close its window before trying again.");
        try{await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(12));}catch(TimeoutException){throw new AppError("This profile refused to close. Save drafts and try again.");}
        await RefreshProcessesAsync();
    }
    static void Activate(int pid){using var process=Process.GetProcessById(pid);var window=process.MainWindowHandle;if(window!=IntPtr.Zero){ShowWindow(window,9);SetForegroundWindow(window);}}
    public static string[] SplitArguments(string command){var ptr=CommandLineToArgvW(command,out var count);if(ptr==IntPtr.Zero)return [];try{return Enumerable.Range(0,count).Select(i=>Marshal.PtrToStringUni(Marshal.ReadIntPtr(ptr,i*IntPtr.Size))??"").ToArray();}finally{LocalFree(ptr);}}
    [DllImport("shell32.dll",SetLastError=true)]static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)]string command,out int argc);
    [DllImport("kernel32.dll")]static extern IntPtr LocalFree(IntPtr ptr);
    [DllImport("user32.dll")]static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]static extern bool ShowWindow(IntPtr window,int command);
}
