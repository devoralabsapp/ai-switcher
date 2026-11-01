using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static partial class PreviewRunner {
    static async Task AntigravityNativeFixtureAsync(string root,string output,string desktop,string cli){
        Require(Environment.GetEnvironmentVariable("GITHUB_ACTIONS")=="true","Antigravity native Windows smoke requires an isolated CI runner.");
        Require(File.Exists(desktop)&&File.Exists(cli),"Official Antigravity Desktop and CLI are required");
        using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(5));var ct=timeout.Token;
        var engine=new AppEngine(Path.Combine(root,"manager"));var repo=engine.Repository;engine.Antigravity.FixtureDiagnostic=message=>File.AppendAllText(Path.Combine(output,"antigravity-startup.txt"),message+"\n");
        var a=new Account{Name="Native Antigravity A",Agent=Agent.Antigravity,AntigravityUsesPrivateHome=true};var b=a with{Id=Guid.NewGuid(),Name="Native Antigravity B"};var c=a with{Id=Guid.NewGuid(),Name="Native Antigravity CLI",AntigravitySignInMethod=AntigravitySignInMethod.Cli};
        foreach(var account in new[]{a,b,c}){Require(engine.SaveAccount(account),"Could not save private Antigravity fixture");repo.PrepareProfile(account);}
        engine.Preferences.Executables["antigravity"]=desktop;engine.Preferences.Executables["antigravityCli"]=cli;engine.SavePreferences();
        var target="antigravity:gemini";var synthetic=Encoding.UTF8.GetBytes("{\"auth_method\":\"consumer\",\"id_token_email\":\"shared-canary@example.test\",\"token\":{\"access_token\":\"synthetic-fixture-no-access\",\"refresh_token\":\"synthetic-fixture-no-access\"}}");
        // Never read, overwrite or delete a pre-existing credential. This probe is
        // only allowed on the disposable CI VM and creates its own synthetic item.
        if(CredRead(target,1,0,out var existing)){CredFree(existing);throw new InvalidOperationException("Fixture refused an existing Antigravity credential");}
        var blob=Marshal.AllocHGlobal(synthetic.Length);bool wrote=false;Exception? primary=null;var phase="Credential Manager canary";
        void Phase(string value){phase=value;File.AppendAllText(Path.Combine(output,"antigravity-phases.txt"),value+"\n");}
        try{
            Marshal.Copy(synthetic,0,blob,synthetic.Length);var credential=new FixtureCredential{Type=1,TargetName=target,UserName="gemini",BlobSize=(uint)synthetic.Length,Blob=blob,Persist=2};
            wrote=CredWrite(ref credential,0);Require(wrote,"Disposable CI Credential Manager canary could not be created; error "+Marshal.GetLastWin32Error());
            Phase("Two native backgrounds");
            foreach(var account in new[]{a,b}){
                await engine.Antigravity.ConnectAsync(account,ct);Require(engine.Antigravity.IsActive(account),"Native private backend did not stay running");await ExpectSignedOut(account);
            }
            Require(engine.Antigravity.BackendPid(a)!=engine.Antigravity.BackendPid(b),"Two Antigravity profiles shared a native backend");CheckCanary();
            Require(!File.Exists(AntigravityProfile.DesktopIdentity(repo,a))&&!File.Exists(AntigravityProfile.DesktopIdentity(repo,b)),"Fresh profiles imported a global sign-in");
            var sentinel=Path.Combine(AntigravityProfile.Home(repo,a),"keep-fixture.txt");File.WriteAllText(sentinel,"preserved");
            await engine.Antigravity.StopAsync(a);Require(engine.Antigravity.IsActive(b),"Stopping A affected B's native backend");await engine.Antigravity.StopAsync(b);
            // Both real Electron windows must own different user-data/native auth homes.
            Phase("Desktop A and B");
            await engine.OpenAsync(a);Require(engine.Platform.Owned(a)?.HasWindow==true,"Native Desktop A failed to open: "+engine.Errors.GetValueOrDefault(a.Id));
            await engine.OpenAsync(b);Require(engine.Platform.Owned(b)?.HasWindow==true,"Native Desktop B failed to open: "+engine.Errors.GetValueOrDefault(b.Id));
            Require(engine.Platform.Owned(a)?.Id!=engine.Platform.Owned(b)?.Id,"Desktop B focused A's window");await ExpectSignedOut(a);await ExpectSignedOut(b);CheckCanary();
            Phase("Desktop close and reopen");
            await engine.CloseAsync(a);Require(!engine.Running(a)&&engine.Running(b),"Close A did not stop its full runtime or affected B");
            await engine.OpenAsync(a);Require(engine.Platform.Owned(a)?.HasWindow==true&&File.ReadAllText(sentinel)=="preserved","Reopening Antigravity lost profile storage");
            // A fresh manager must rediscover the exact saved native process and HTTP listener.
            Phase("Manager rediscovery");
            var restarted=new AppEngine(repo.Root);await restarted.Platform.FindExecutableAsync("antigravity");await restarted.Platform.RefreshProcessesAsync();
            await ExpectSignedOut(a,restarted);await ExpectSignedOut(b,restarted);
            await engine.CloseAsync(a);Require(!engine.Running(a)&&engine.Running(b),"Closing reopened A affected B");
            await engine.CloseAsync(b);Require(!engine.Running(b),"Close B left a native helper running");
            // Exercise the real CLI's /usage, not a fake parser or an early metadata check.
            Phase("Official CLI usage");
            var info=ChildEnvironment.StartInfo(cli,ProviderQuota.AntigravityArguments,AntigravityProfile.Environment(NativePlatform.EnvironmentValues(),repo,c),AntigravityProfile.Home(repo,c));info.RedirectStandardInput=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
            using(var command=Process.Start(info)!){
                command.StandardInput.Close();var captured=new StringBuilder();
                void Capture(object sender,DataReceivedEventArgs e){if(e.Data!=null)lock(captured){if(captured.Length<1048576)captured.AppendLine(e.Data[..Math.Min(e.Data.Length,1048576-captured.Length)]);}}
                command.OutputDataReceived+=Capture;command.ErrorDataReceived+=Capture;command.BeginOutputReadLine();command.BeginErrorReadLine();
                void Diagnose(){lock(captured){var text=captured.ToString();var terms=new[]{"file-based token storage","WSL environment","not signed in","not logged in","sign in","login","authenticate","authentication","no controlling terminal","not authenticated","print mode","updat","WSL","wslpath","terminal","keyring","error","permission","timeout","Listening","onboarding","color scheme"};File.WriteAllText(Path.Combine(output,"antigravity-cli-diagnostics.txt"),"Output chars: "+text.Length+"\n"+string.Join("\n",terms.Where(x=>text.Contains(x,StringComparison.OrdinalIgnoreCase))));}}
                try{await command.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(45),ct);}catch{Diagnose();if(!command.HasExited){command.Kill(true);await command.WaitForExitAsync();}throw;}
                Diagnose();string text;lock(captured)text=captured.ToString();
                Require(text.Length<1048576&&text.Contains("Using file-based token storage because WSL environment detected",StringComparison.Ordinal),"Official CLI did not select its private file storage adapter");
                Require(new[]{"not signed in","not logged in","sign in","login","authenticate","authentication"}.Any(x=>text.Contains(x,StringComparison.OrdinalIgnoreCase)),"Fresh private CLI was not signed out");
                Require(!File.Exists(AntigravityProfile.CliIdentity(repo,c)),"CLI imported a global identity into the fresh profile");
            }
            CheckCanary();
            // Explicit Login must keep a local callback; no Google credentials or consent are entered.
            Phase("Browser localhost callback");
            await engine.Antigravity.ConnectAsync(a,ct);using(var loginCancellation=CancellationTokenSource.CreateLinkedTokenSource(ct)){
                var login=engine.Antigravity.SignInAsync(a,loginCancellation.Token);var observed=false;
                for(var i=0;i<60&&!observed;i++){
                    await Task.Delay(250,ct);await engine.Platform.RefreshProcessesAsync();
                    foreach(var arg in engine.Platform.Processes.SelectMany(p=>p.Arguments)){
                        foreach(System.Text.RegularExpressions.Match match in System.Text.RegularExpressions.Regex.Matches(arg,@"https://accounts\.google\.com/[^\s""<>]+")){
                            if(!Uri.TryCreate(match.Value,UriKind.Absolute,out var uri))continue;
                            var redirect=uri.Query.TrimStart('?').Split('&').FirstOrDefault(x=>x.StartsWith("redirect_uri=",StringComparison.Ordinal));
                            if(redirect!=null&&Uri.TryCreate(Uri.UnescapeDataString(redirect[13..]),UriKind.Absolute,out var callback)&&callback.Scheme=="http"&&callback.Host is "localhost" or "127.0.0.1")observed=true;
                        }
                    }
                }
                loginCancellation.Cancel();try{await login;}catch(OperationCanceledException){}
                Require(observed,"Official Windows browser login did not expose a Google destination with localhost callback");
            }
            await engine.Antigravity.StopAsync(a);CheckCanary();
            File.WriteAllText(Path.Combine(output,"antigravity-native-result.txt"),"PASS: official Windows Antigravity Desktop and CLI; private vendor file storage selected; two independent fresh native backgrounds and Desktop windows stay signed out with a global synthetic Credential Manager canary present; CLI /usage uses private storage without model input; separate native HTTP/CSRF endpoints; close/reopen and manager restart preserve ownership and data; closing A preserves B; global canary unchanged; explicit Google browser Login uses a localhost callback and is cancelled before authentication. Live Google sign-in and live subscription quotas are not exercised.\n");
        }catch(Exception error){primary=error;File.WriteAllText(Path.Combine(output,"antigravity-primary-error.txt"),phase+"\n"+error);throw;}
        finally{
            Exception? cleanup=null;
            try{await engine.ShutdownAsync();}catch(Exception error){cleanup=error;}
            foreach(var account in new[]{a,b,c}){try{await engine.Platform.ForceStopAsync(account);if(repo.Load().Accounts.Any(x=>x.Id==account.Id))repo.Remove(account,repo.Load());}catch(Exception error){cleanup??=error;}}
            try{if(wrote){CheckCanary();Require(CredDelete(target,1,0),"Could not delete fixture credential");}}catch(Exception error){cleanup??=error;}finally{Marshal.FreeHGlobal(blob);}
            if(cleanup!=null){File.WriteAllText(Path.Combine(output,"antigravity-cleanup-error.txt"),cleanup.ToString());if(primary==null)throw cleanup;}
        }
        async Task ExpectSignedOut(Account account,AppEngine? manager=null){try{await (manager??engine).Antigravity.ReadAsync(account,ct);}catch(AppError error)when(error.Key==ProviderQuota.SignedOut){return;}throw new InvalidOperationException("Fresh private profile was not signed out");}
        void CheckCanary(){Require(CredRead(target,1,0,out var pointer),"Fixture credential disappeared");try{var value=Marshal.PtrToStructure<FixtureCredential>(pointer);var bytes=new byte[value.BlobSize];Marshal.Copy(value.Blob,bytes,0,bytes.Length);Require(bytes.SequenceEqual(synthetic),"Private session changed shared Credential Manager storage");}finally{CredFree(pointer);}}
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct FixtureCredential {public uint Flags,Type;public string? TargetName,Comment;public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;public uint BlobSize;public IntPtr Blob;public uint Persist,AttributeCount;public IntPtr Attributes;public string? TargetAlias,UserName;}
    [DllImport("advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredRead(string target,uint type,uint flags,out IntPtr credential);
    [DllImport("advapi32.dll",EntryPoint="CredWriteW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredWrite(ref FixtureCredential credential,uint flags);
    [DllImport("advapi32.dll",EntryPoint="CredDeleteW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredDelete(string target,uint type,uint flags);
    [DllImport("advapi32.dll")]static extern void CredFree(IntPtr credential);
}
