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
        var engine=new AppEngine(Path.Combine(root,"manager"));var repo=engine.Repository;var diagnosticLock=new object();engine.Antigravity.FixtureDiagnostic=message=>{lock(diagnosticLock)File.AppendAllText(Path.Combine(output,"antigravity-startup.txt"),message+"\n");};
        var a=new Account{Name="Native Antigravity A",Agent=Agent.Antigravity,AntigravityUsesPrivateHome=true};var b=a with{Id=Guid.NewGuid(),Name="Native Antigravity B"};var c=a with{Id=Guid.NewGuid(),Name="Native Antigravity CLI",AntigravitySignInMethod=AntigravitySignInMethod.Cli};
        foreach(var account in new[]{a,b,c}){Require(engine.SaveAccount(account),"Could not save private Antigravity fixture");repo.PrepareProfile(account);}
        engine.Preferences.Executables["antigravity"]=desktop;engine.Preferences.Executables["antigravityCli"]=cli;engine.SavePreferences();
        var targets=new[]{"gemini:antigravity","gemini:antigravity-cli","antigravity:gemini"};var synthetic=Encoding.UTF8.GetBytes("{\"auth_method\":\"consumer\",\"id_token_email\":\"shared-canary@example.test\",\"token\":{\"access_token\":\"synthetic-fixture-no-access\",\"refresh_token\":\"synthetic-fixture-no-access\"}}");
        // Never read, overwrite or delete a pre-existing credential. This probe is
        // only allowed on the disposable CI VM and creates its own synthetic item.
        foreach(var target in targets)if(CredRead(target,1,0,out var existing)){CredFree(existing);throw new InvalidOperationException("Fixture refused an existing Antigravity credential");}
        var blob=Marshal.AllocHGlobal(synthetic.Length);var createdTargets=new List<string>();Exception? primary=null;var phase="Credential Manager canary";Process? unrelatedBrowser=null;
        void Phase(string value){phase=value;File.AppendAllText(Path.Combine(output,"antigravity-phases.txt"),value+"\n");}
        try{
            Marshal.Copy(synthetic,0,blob,synthetic.Length);
            foreach(var target in targets){var credential=new FixtureCredential{Type=1,TargetName=target,UserName=target.Split(':')[1],BlobSize=(uint)synthetic.Length,Blob=blob,Persist=2};
                Require(CredWrite(ref credential,0),"Disposable CI Credential Manager canary could not be created; error "+Marshal.GetLastWin32Error());createdTargets.Add(target);
            }
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
            var restarted=new AppEngine(repo.Root);restarted.Antigravity.FixtureDiagnostic=engine.Antigravity.FixtureDiagnostic;await restarted.Platform.FindExecutableAsync("antigravity");await restarted.Platform.RefreshProcessesAsync();
            await ExpectSignedOut(a,restarted);await ExpectSignedOut(b,restarted);
            await engine.CloseAsync(a);Require(!engine.Running(a)&&engine.Running(b),"Closing reopened A affected B");
            await engine.CloseAsync(b);Require(!engine.Running(b),"Close B left a native helper running");
            Phase("Shared all-project catalog and existing conversations");
            var source = Path.Combine(root, "original-desktop-home");
            var projects = Path.Combine(source, ".gemini", "config", "projects");
            Directory.CreateDirectory(projects);
            foreach (var name in new[] { "One", "Two" })
                File.WriteAllText(Path.Combine(projects, name + ".json"), JsonSerializer.Serialize(new { id = Guid.NewGuid().ToString(), name, projectResources = new { } }));
            var sourceIdentity = Path.Combine(source, ".gemini", "jetski-standalone-oauth-token");
            File.WriteAllText(sourceIdentity, "source identity canary");
            var shared = new AntigravityDesktopService(repo, engine.Platform, source);
            try
            {
                await shared.ConnectAsync(a, ct);
                var created = await shared.FixtureRequestAsync(a, "StartCascade", new { source = "CORTEX_TRAJECTORY_SOURCE_INTERACTIVE_CASCADE" }, ct);
                var id = created.GetProperty("cascadeId").GetString()!;
                await shared.StopAsync(a);
                var sharedA = a with { AntigravitySharesLocalProjects = true };
                var sharedB = b with { AntigravitySharesLocalProjects = true };
                await shared.ConnectAsync(sharedA, ct);
                await shared.IndexSharedConversationsAsync(sharedA, ct);
                Require(new SharedAntigravityWorkspace(repo, source).ConversationIDs().Contains(id), "Imported history was not registered");
                var newConversation = await shared.FixtureRequestAsync(sharedA, "StartCascade", new { source = "CORTEX_TRAJECTORY_SOURCE_INTERACTIVE_CASCADE" }, ct);
                var newID = newConversation.GetProperty("cascadeId").GetString()!;
                await shared.StopAsync(sharedA);
                await shared.ConnectAsync(sharedB, ct);
                await shared.IndexSharedConversationsAsync(sharedB, ct);
                var found = false;
                for (var attempt = 0; attempt < 40; attempt++)
                {
                    var listed = await shared.FixtureRequestAsync(sharedB, "GetAllCascadeTrajectories", null, ct);
                    if (listed.TryGetProperty("trajectorySummaries", out var summaries) && summaries.TryGetProperty(id, out _) && summaries.TryGetProperty(newID, out _)) { found = true; break; }
                    await Task.Delay(250, ct);
                }
                Require(found, "Account B could not list A's imported local conversation");
                var read = await shared.FixtureRequestAsync(sharedB, "GetCascadeTrajectory", new { cascadeId = id }, ct);
                Require(read.GetProperty("trajectory").GetProperty("cascadeId").GetString() == id, "Conversation ID changed across accounts");
                foreach (var account in new[] { sharedA, sharedB })
                {
                    var registry = Path.Combine(AntigravityProfile.Home(repo, account), ".gemini", "config", "projects");
                    Require(File.Exists(Path.Combine(registry, "One.json")) && File.Exists(Path.Combine(registry, "Two.json")), "Shared catalog lost a Desktop project");
                    Require(!File.Exists(AntigravityProfile.DesktopIdentity(repo, account)), "Sharing imported another account's login");
                }
                try { await shared.ReadAsync(sharedB, ct); throw new InvalidOperationException("Shared history imported source login"); }
                catch (AppError error) when (error.Key == ProviderQuota.SignedOut) { }
                Require(File.ReadAllText(sourceIdentity) == "source identity canary", "Source login was changed");
                await shared.StopAsync(sharedB);
                await new SharedAntigravityWorkspace(repo, source).PrepareAsync(a, SharedWorkspace.JunctionAsync);
                await new SharedAntigravityWorkspace(repo, source).PrepareAsync(b, SharedWorkspace.JunctionAsync);
                Require(File.Exists(Path.Combine(AntigravityProfile.Home(repo, a), ".gemini", "antigravity", "conversations", id + ".db")), "Turning off sharing lost original private history");
                Require(File.Exists(Path.Combine(source, ".gemini", "antigravity", "conversations", id + ".db")), "Turning off sharing deleted shared history");
                CheckCanary();
            }
            finally { await shared.StopAllAsync(); }
            // Explicit Login must keep a local callback; no Google credentials or consent are entered.
            Phase("Browser localhost callback");
            var browser=await engine.Platform.FindExecutableAsync("edge")??throw new InvalidOperationException("Edge is required for the browser ownership fixture");var unrelatedData=Path.Combine(root,"unrelated-browser");Directory.CreateDirectory(unrelatedData);
            unrelatedBrowser=Process.Start(ChildEnvironment.StartInfo(browser,new[]{"--user-data-dir="+unrelatedData,"--no-first-run","--disable-background-mode","about:blank"},ChildEnvironment.Create(NativePlatform.EnvironmentValues()),Environment.GetFolderPath(Environment.SpecialFolder.System)))!;
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
            IReadOnlyList<OwnedProcess> oauth=[];for(var i=0;i<40;i++){await engine.ObserveAsync(false);oauth=await engine.Platform.AntigravityOAuthBrowsersAsync(a);if(oauth.Count>0)break;await Task.Delay(250,ct);}
            Require(oauth.Count>0,"Private browser storage was not attributed to the selected profile");Require(oauth.All(p=>p.Id!=unrelatedBrowser.Id),"Unrelated browser was adopted as a private OAuth window");
            await engine.Antigravity.StopAsync(a);await engine.ObserveAsync(false);Require(engine.Running(a),"Private OAuth browser must retain a closeable session after cancellation");
            await engine.CloseAsync(a);Require(!engine.Running(a),"Cancelled OAuth left private browser or native processes running");Require(!unrelatedBrowser.HasExited,"Closing Antigravity stopped an unrelated browser");CheckCanary();
            // Exercise the real CLI's /usage, not a fake parser or an early metadata check.
            Phase("Official CLI usage");Require(GetConsoleCP()==0,"GUI manager retained a controlling console");
            // glog's default cli.log is a link. Ask the official CLI for an
            // ordinary, profile-owned log rather than following that alias.
            var log=Path.Combine(AntigravityProfile.Home(repo,c),"native-fixture.log");Repository.RejectLinks(log);
            var info=ChildEnvironment.StartInfo(cli,ProviderQuota.AntigravityArguments.Concat(new[]{"--log-file",log}),AntigravityProfile.Environment(NativePlatform.EnvironmentValues(),repo,c),AntigravityProfile.Home(repo,c));info.Environment["CI"]="true";info.RedirectStandardInput=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
            await using(var command=DetachedCommand.Start(info)){
                command.Input.Close();var captured=new StringBuilder();
                async Task Capture(StreamReader reader){var buffer=new char[4096];int count;while((count=await reader.ReadAsync(buffer,ct))>0)lock(captured){if(captured.Length+count>1048576)throw new InvalidOperationException("CLI probe output too large");captured.Append(buffer,0,count);}}
                var stdout=Capture(command.Output);var stderr=Capture(command.Error);
                void Diagnose(){lock(captured){var text=captured.ToString();var terms=new[]{"file-based token storage","WSL environment","not signed in","not logged in","sign in","login","authenticate","authentication","no controlling terminal","not authenticated","print mode","updat","WSL","wslpath","terminal","keyring","error","permission","timeout","Listening","onboarding","color scheme"};File.WriteAllText(Path.Combine(output,"antigravity-cli-diagnostics.txt"),"Output chars: "+text.Length+"\n"+string.Join("\n",terms.Where(x=>text.Contains(x,StringComparison.OrdinalIgnoreCase))));}}
                try{await command.Process.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(30),ct);await Task.WhenAll(stdout,stderr);}catch{Diagnose();if(!command.Process.HasExited){command.Process.Kill(true);await command.Process.WaitForExitAsync();}throw;}
                Diagnose();string text;lock(captured)text=captured.ToString();
                Repository.RejectLinks(log);
                if(File.Exists(log)){using var reader=File.OpenRead(log);var bytes=new byte[524288];var count=reader.Read(bytes,0,bytes.Length);text+="\n"+Encoding.UTF8.GetString(bytes,0,count);}
                Require(text.Length<1572864&&text.Contains("Using file-based token storage because WSL environment detected",StringComparison.Ordinal),"Official CLI did not select its private file storage adapter");
                Require(ProviderQuota.AntigravityRequiresSignIn(text),"Fresh private CLI was not signed out");
                Require(!File.Exists(AntigravityProfile.CliIdentity(repo,c)),"CLI imported a global identity into the fresh profile");
            }
            CheckCanary();
        }catch(Exception error){primary=error;File.WriteAllText(Path.Combine(output,"antigravity-primary-error.txt"),phase+"\n"+error);throw;}
        finally{
            Exception? cleanup=null;
            try{await engine.ShutdownAsync();}catch(Exception error){cleanup=error;}
            if(unrelatedBrowser!=null){try{if(!unrelatedBrowser.HasExited){unrelatedBrowser.Kill(true);await unrelatedBrowser.WaitForExitAsync();}}catch(ArgumentException){}finally{unrelatedBrowser.Dispose();}}
            foreach(var account in new[]{a,b,c}){try{await engine.Platform.ForceStopAsync(account);if(repo.Load().Accounts.Any(x=>x.Id==account.Id))repo.Remove(account,repo.Load());}catch(Exception error){cleanup??=new InvalidOperationException("Cleanup "+account.Name,error);}}
            try{foreach(var target in createdTargets){CheckCredential(target);Require(CredDelete(target,1,0),"Could not delete fixture credential");}}catch(Exception error){cleanup??=error;}finally{Marshal.FreeHGlobal(blob);}
            if(cleanup!=null){
                File.WriteAllText(Path.Combine(output,"antigravity-cleanup-error.txt"),cleanup.ToString());
                // This signed diagnostic is supplied only by the disposable CI
                // fixture. Capture handle names while the manager is still alive.
                if(Environment.GetEnvironmentVariable("AISW_FIXTURE_HANDLE") is {} handle&&File.Exists(handle)){
                    var start=new ProcessStartInfo(handle){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};foreach(var value in new[]{"-accepteula","-nobanner","-a",a.Id.ToString("D")})start.ArgumentList.Add(value);
                    using var diagnostic=Process.Start(start)!;var text=diagnostic.StandardOutput.ReadToEndAsync();var error=diagnostic.StandardError.ReadToEndAsync();await diagnostic.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
                    File.WriteAllText(Path.Combine(output,"antigravity-live-fixture-handles.txt"),(await text)+"\n"+(await error));
                }
                File.WriteAllText(Path.Combine(output,"antigravity-fixture-attributes.txt"),string.Join("\n",new[]{a,b,c}.Select(account=>account.Name+": "+(Directory.Exists(repo.ProfilePath(account))?File.GetAttributes(repo.ProfilePath(account)).ToString()+"; "+System.IO.FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(repo.ProfilePath(account))).GetSecurityDescriptorSddlForm(System.Security.AccessControl.AccessControlSections.Access|System.Security.AccessControl.AccessControlSections.Owner|System.Security.AccessControl.AccessControlSections.Group):"removed"))));
                IEnumerable<string> Paths(string directory){foreach(var path in Directory.EnumerateFileSystemEntries(directory)){var attributes=File.GetAttributes(path);yield return Path.GetRelativePath(repo.ProfilePath(a),path)+": "+attributes;if(attributes.HasFlag(FileAttributes.Directory)&&!attributes.HasFlag(FileAttributes.ReparsePoint))foreach(var nested in Paths(path))yield return nested;}}
                if(Directory.Exists(repo.ProfilePath(a)))File.WriteAllText(Path.Combine(output,"antigravity-fixture-paths.txt"),string.Join("\n",Paths(repo.ProfilePath(a)).Take(5000)));
                if(primary==null)throw cleanup;
            }
        }
            File.WriteAllText(Path.Combine(output,"antigravity-native-result.txt"),"PASS: official Windows Antigravity Desktop and CLI; private vendor file storage selected; two independent fresh native backgrounds and Desktop windows stay signed out with a global synthetic Credential Manager canary present; CLI /usage uses private storage without model input; separate native HTTP/CSRF endpoints; all-project junction sharing imports existing private conversation IDs, indexes them under account B and restores originals when disabled; close/reopen and manager restart preserve ownership and data; account directories can be removed after cancelled browser OAuth; closing A preserves B; global canary unchanged; explicit Google browser Login uses a localhost callback and is cancelled before authentication. Live Google sign-in and live subscription quotas are not exercised.\n");
        async Task ExpectSignedOut(Account account,AppEngine? manager=null){try{await (manager??engine).Antigravity.ReadAsync(account,ct);}catch(AppError error)when(error.Key==ProviderQuota.SignedOut){return;}throw new InvalidOperationException("Fresh private profile was not signed out");}
        void CheckCanary(){foreach(var target in targets)CheckCredential(target);}
        void CheckCredential(string target){Require(CredRead(target,1,0,out var pointer),"Fixture credential disappeared");try{var value=Marshal.PtrToStructure<FixtureCredential>(pointer);var bytes=new byte[value.BlobSize];Marshal.Copy(value.Blob,bytes,0,bytes.Length);Require(bytes.SequenceEqual(synthetic),"Private session changed shared Credential Manager storage");}finally{CredFree(pointer);}}
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct FixtureCredential {public uint Flags,Type;public string? TargetName,Comment;public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;public uint BlobSize;public IntPtr Blob;public uint Persist,AttributeCount;public IntPtr Attributes;public string? TargetAlias,UserName;}
    [DllImport("kernel32.dll")]static extern uint GetConsoleCP();
    [DllImport("advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredRead(string target,uint type,uint flags,out IntPtr credential);
    [DllImport("advapi32.dll",EntryPoint="CredWriteW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredWrite(ref FixtureCredential credential,uint flags);
    [DllImport("advapi32.dll",EntryPoint="CredDeleteW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredDelete(string target,uint type,uint flags);
    [DllImport("advapi32.dll")]static extern void CredFree(IntPtr credential);
}
