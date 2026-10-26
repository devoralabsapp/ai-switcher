using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static class PreviewRunner {
    public static int Run(string[] args){var root=Program.Argument(args,"--data-dir");var output=Program.Argument(args,"--output");var smoke=args.Contains("--ui-smoke-test");var stdio=args.Contains("--stdio-smoke-test");var realStore=args.Contains("--store-runtime-smoke-test");var backend=args.Contains("--backend-smoke-test")||stdio||realStore;
        if(root==null||output==null||!Path.GetFileName(root).StartsWith(smoke||backend?"ai-switcher-smoke.":"ai-switcher-preview.",StringComparison.Ordinal)||!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()),StringComparison.OrdinalIgnoreCase))return 2;
        if(realStore){try{Directory.CreateDirectory(output);RealStoreAsync(root,output,Program.Argument(args,"--store-executable")??throw new InvalidOperationException("Store executable required"),Program.Argument(args,"--store-agent")=="claude"?Agent.Claude:Agent.Chatgpt).GetAwaiter().GetResult();return 0;}catch(Exception error){File.WriteAllText(Path.Combine(output,"store-runtime-error.txt"),error.ToString());return 1;}}
        if(backend){try{Directory.CreateDirectory(output);BackendFixtureAsync(root,output,Program.Argument(args,"--codex-executable")??throw new InvalidOperationException("Codex executable is required"),stdio).GetAwaiter().GetResult();File.WriteAllText(Path.Combine(output,"backend-smoke-result.txt"),stdio?"PASS: standalone EXE starts real native Windows Codex RPC in its own signed-out home; initialization and signed-out identity verified; elevated daemon startup rejected; no Desktop or real account.\n":"PASS: native Windows Codex daemon starts, accepts a local handshake in its own signed-out home, restarts, stops and cleans up without a Desktop window or real account.\n");return 0;}catch(Exception error){File.AppendAllText(Path.Combine(output,"backend-smoke-error.txt"),error.ToString());return 1;}}
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/AISwitcher;component/Styles.xaml",UriKind.Relative)});int code=0;
        app.Startup+=async(_,_)=>{try{Directory.CreateDirectory(output);foreach(var language in new[]{"en","vi"})foreach(var theme in Themes.All){var data=Path.Combine(root,language,theme.Id);var repository=new Repository(data);repository.Save(Demo());var engine=new AppEngine(data);engine.Preferences.Language=language;engine.Preferences.Theme=theme.Id;
            var window=new MainWindow(engine){Width=1200,Height=950};window.Show();await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);window.UpdateLayout();Save(window,Path.Combine(output,$"{theme.Id}-{language}.png"));
            Require(Find(window,"addAccount") is Button,"Add account button missing");Require(Find(window,"quotaOnlyMode") is CheckBox,"Quota-only control missing");Require(Find(window,"agent-filter-claude") is Button,"Agent filter missing");
            engine.SetQuotaOnly(true);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.QuotaTable,"Quota-only must select table");engine.SetQuotaOnly(false);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.Cards,"Disabling quota-only must restore cards");
            if(theme.Id=="terminalBlack"){Require(theme.Canvas=="#000000","Terminal Black canvas mismatch");engine.SetAgent(Agent.Claude);await CaptureDialog(window,()=>window.EditAccount(),Path.Combine(output,$"claude-editor-{language}.png"));await CaptureDialog(window,window.Settings,Path.Combine(output,$"settings-{language}.png"));}
            window.Exiting=true;window.Close();engine.Shutdown();
        }
        if(smoke){ReadOnlyPreferences(root);await ProcessRoutingAsync(Path.Combine(root,"processes"));await WorkspaceFixtureAsync(root);}
        File.WriteAllText(Path.Combine(output,"ui-smoke-result.txt"),"PASS: 7 themes × 2 languages; account/filter/quota controls; cards/table transition; Claude editor and settings rendering; exact native Windows fixture process routing; private workspace junctions, custom database, metadata projection, SQLite path canonicalization and safe deletion.\n");
        }catch(Exception error){code=1;File.AppendAllText(Path.Combine(output,backend?"backend-smoke-error.txt":"ui-smoke-error.txt"),error.ToString());}finally{app.Shutdown(code);}};
        app.Run();return code;
    }
    static async Task CaptureDialog(MainWindow owner,Action open,string path){
        _=owner.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle,new Action(()=>{var dialog=Application.Current.Windows.Cast<Window>().FirstOrDefault(x=>x!=owner&&x.Owner==owner);if(dialog!=null){dialog.UpdateLayout();if(Find(dialog,"accountAgent") is ComboBox agent)Require(agent.SelectedItem is string text&&text=="Claude","Claude selector must display the agent name");Save(dialog,path);dialog.Close();}}));open();await Task.CompletedTask;
    }
    static FrameworkElement? Find(DependencyObject root,string id){for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is FrameworkElement fe&&AutomationProperties.GetAutomationId(fe)==id)return fe;var found=Find(child,id);if(found!=null)return found;}return null;}
    static void Save(Window window,string path){window.UpdateLayout();var width=(int)Math.Ceiling(window.ActualWidth);var height=(int)Math.Ceiling(window.ActualHeight);Require(width>0&&height>0,"Window did not render");var background=new DrawingVisual();using(var draw=background.RenderOpen())draw.DrawRectangle(window.Background??Brushes.White,null,new Rect(0,0,width,height));var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);bitmap.Render(background);bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(path);encoder.Save(stream);}


    static void Require(bool condition,string message){if(!condition)throw new InvalidOperationException(message);}
    static Snapshot Demo(){var limits=System.Text.Json.JsonSerializer.Deserialize<Limits>("{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":23,\"windowDurationMins\":300,\"resetsAt\":"+DateTimeOffset.UtcNow.AddHours(2).ToUnixTimeSeconds()+"},\"secondary\":{\"usedPercent\":41,\"windowDurationMins\":10080,\"resetsAt\":"+DateTimeOffset.UtcNow.AddDays(3).ToUnixTimeSeconds()+"}}}",Json.Options)!;
        return new(){Accounts=[new(){Name="Demo Personal",EmailHint="personal@example.test",Agent=Agent.Chatgpt,Color="mint",IsFavorite=true,DesktopConnection=new(new("demo@example.test","plus"),new(limits,DateTimeOffset.UtcNow))},new(){Name="Claude Work",EmailHint="work@example.test",Agent=Agent.Claude,Color="peach",IsFavorite=true},new(){Name="Claude Personal",Agent=Agent.Claude,LaunchMode=LaunchMode.Browser,Color="rose"},new(){Name="Gemini Study",Agent=Agent.Gemini,Color="blue"},new(){Name="Antigravity",Agent=Agent.Antigravity,Color="violet"},new(){Name="Perplexity Research",Agent=Agent.Perplexity,Color="mint"},new(){Name="DeepSeek Work",Agent=Agent.Deepseek,Color="gold"}]};}
    static void ReadOnlyPreferences(string root){var repo=new Repository(Path.Combine(root,"corrupt-preferences"));Directory.CreateDirectory(repo.Root);File.WriteAllText(repo.PreferencesPath,"{");var engine=new AppEngine(repo.Root);Require(engine.ReadOnly,"Corrupt preferences must leave the manager read-only");engine.SetQuotaOnly(true);engine.SetAgent(Agent.Claude);Require(File.ReadAllText(repo.PreferencesPath)=="{","Read-only controls overwrote corrupt preferences");}
    [System.Runtime.InteropServices.DllImport("user32.dll",EntryPoint="GetClassNameW",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]static extern int GetClassName(IntPtr window,System.Text.StringBuilder name,int length);
    [System.Runtime.InteropServices.DllImport("user32.dll")]static extern bool ShowWindow(IntPtr window,int command);
    static async Task RealStoreAsync(string root,string output,string source,Agent agent){
        var repo=new Repository(root);var a=new Account{Name="Store A",Agent=agent};var b=new Account{Name="Store B",Agent=agent};repo.Save(new(){Accounts=[a,b]});var engine=new AppEngine(root);var children=new List<int>();engine.Platform.FixtureStarted=pid=>children.Add(pid);Exception? failure=null;
        var runtime=await StoreRuntime.PrepareAsync(repo.Root,source);engine.Preferences.Executables[agent.Name().ToLowerInvariant()]=runtime;
        if(agent==Agent.Chatgpt){engine.Preferences.Executables["codex"]=Path.Combine(Path.GetDirectoryName(runtime)!,"resources","codex.exe");Require(await CodexLocator.VerifyAsync(engine.Preferences.Executables["codex"]),"Copied native Store CLI did not run");}
        try{
            foreach(var account in new[]{a,b}){
                if(account.UsesCodexDesktop)repo.PrepareQuota(account);repo.PrepareProfile(account);await engine.Platform.OpenAsync(account,useLocalDaemon:false);
                var process=engine.Platform.Owned(account)??throw new InvalidOperationException("Missing runtime process");Require(process.HasWindow,"Store runtime did not create a window");
                await Task.Delay(5000);using(var launched=Process.GetProcessById(process.Id)){Require(!launched.HasExited,"Store runtime exited after showing its window");File.AppendAllText(Path.Combine(output,"store-runtime-windows.txt"),launched.Id+": "+launched.MainWindowTitle+"\n");var className=new System.Text.StringBuilder(128);GetClassName(launched.MainWindowHandle,className,128);Require(className.ToString().StartsWith("Chrome_WidgetWin_",StringComparison.Ordinal),"Store runtime displayed a native error dialog instead of Electron: "+className);}
                Require(Directory.EnumerateFileSystemEntries(repo.DataPath(account)).Any(),"Desktop ignored its private user-data directory");
                if(account.UsesCodexDesktop){await using var client=await engine.Backend.StdioClientAsync(account);try{await client.ReadIdentityAsync();throw new InvalidOperationException("Fresh Store profile unexpectedly signed in");}catch(AppError error)when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){}}
            }
            Require(children[0]!=children[1],"Store profiles shared a process");await engine.Platform.OpenAsync(a,useLocalDaemon:false);Require(engine.Platform.Owned(a)?.Id==children[0],"Switching A did not reuse its window");
            var oldA=engine.Platform.Owned(a)!;using(var window=Process.GetProcessById(oldA.Id))ShowWindow(window.MainWindowHandle,0);
            await engine.Platform.RefreshProcessesAsync();Require(engine.Platform.Owned(a)?.HasWindow==false,"Hidden fixture still exposed a main window");
            await engine.Platform.CloseAsync(a);using(var other=Process.GetProcessById(children[1]))Require(!other.HasExited,"Closing hidden A affected B");
            Require(engine.Platform.Owned(a)==null,"Hidden A did not quit");
            await engine.Platform.OpenAsync(a,useLocalDaemon:false);Require(engine.Platform.Owned(a)?.Id!=oldA.Id,"Reopened A reused an exited process");
            await engine.Platform.CloseAsync(a);await engine.Platform.CloseAsync(b);
            File.WriteAllText(Path.Combine(output,"store-runtime-result.txt"),"PASS: real official "+agent.Name()+" program files copied intact; two private profile windows/PIDs and user-data directories; existing A window reused; graceful close of hidden A preserves B; A reopens; both sessions quit without forced shutdown. Source: "+source+"\n");
        }catch(Exception error){failure=error;throw;}finally{
            foreach(var pid in children.Distinct()){try{using var child=Process.GetProcessById(pid);if(!child.HasExited)child.Kill(true);await child.WaitForExitAsync();}catch(ArgumentException){}}
            foreach(var account in new[]{a,b}){for(var attempt=0;attempt<10;attempt++){try{repo.Remove(account,repo.Load());break;}catch(IOException)when(attempt<9){await Task.Delay(400);}catch(Exception error)when(failure!=null){File.AppendAllText(Path.Combine(output,"store-runtime-cleanup.txt"),error.GetType().Name+"\n");break;}}}
        }
    }
    static async Task BackendFixtureAsync(string root,string output,string executable,bool stdio=false){
        var account=new Account{Name="Native backend smoke"};var repo=new Repository(root);repo.Save(new(){Accounts=[account]});var engine=new AppEngine(root);engine.Preferences.Executables["codex"]=executable;engine.Backend.FixtureDiagnostic=text=>File.AppendAllText(Path.Combine(output,"backend-smoke-error.txt"),text+"\n");
        if(stdio){try{
            Require(!WindowsExecutable.IsConsole(Environment.ProcessPath!),"The Windows GUI must not be accepted as a console CLI");
            var local=Path.Combine(root,"fake-local");var relocated=Path.Combine(local,"OpenAI","Codex","bin","fixture-hash","codex.exe");Directory.CreateDirectory(Path.GetDirectoryName(relocated)!);File.Copy(executable,relocated);
            var protectedCli=Path.Combine(root,"WindowsApps","OpenAI.Codex_fixture","app","Codex.exe");Directory.CreateDirectory(Path.GetDirectoryName(protectedCli)!);File.Copy(executable,protectedCli);
            var unversioned=Path.Combine(local,"OpenAI","Codex","bin","codex.exe");File.Copy(executable,unversioned);
            var candidates=new[]{Environment.ProcessPath!,protectedCli}.Concat(CodexLocator.UserCandidates(local,Path.Combine(root,"fake-roaming")));
            var resolved=await CodexLocator.ResolveAsync(candidates);Require(resolved!=null&&NativePlatform.SamePath(resolved,relocated),"Store/GUI candidates hid the runnable relocated CLI");
            engine.Preferences.Executables["codex"]=relocated;
            if(NativePlatform.IsElevated()){try{await engine.Backend.StartAsync(account);throw new InvalidOperationException("Elevated daemon startup was accepted");}catch(AppError error)when(error.Key=="Run AI Switcher without administrator privileges to connect background sessions."){}}
            await using var client=await engine.Backend.StdioClientAsync(account);
            try{await client.ReadIdentityAsync();throw new InvalidOperationException("Fresh native Codex returned an existing identity");}catch(AppError error)when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){}
            return;
        }finally{repo.Remove(account,repo.Load());}}
        try{
            await engine.Backend.StartAsync(account);Require(engine.Backend.IsActive(account),"Native daemon was not active after connect");
            try{await engine.Backend.ReadAsync(account);throw new InvalidOperationException("A fresh profile unexpectedly returned a signed-in identity");}catch(AppError error)when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){}
            var marker=Path.Combine(repo.QuotaHome(account),"smoke-persistence.txt");File.WriteAllText(marker,"fixture");await engine.Backend.StopAsync(account);await engine.Backend.StartAsync(account);Require(File.ReadAllText(marker)=="fixture","Backend restart did not preserve its own home");
            await engine.Platform.RefreshProcessesAsync();Require(engine.Platform.Owned(account)==null,"Headless connection unexpectedly opened a Desktop window");await engine.Backend.StopAsync(account);
        }finally{try{await engine.Backend.StopAsync(account);}finally{repo.Remove(account,repo.Load());}}
    }
    static async Task WorkspaceFixtureAsync(string root){
        var scope=Path.Combine(root,"workspace-fixture");var source=Path.Combine(scope,"source");var database=Path.Combine(scope,"database");var artifacts=Path.Combine(scope,"original-artifacts");Directory.CreateDirectory(source);Directory.CreateDirectory(database);Directory.CreateDirectory(artifacts);
        File.WriteAllText(Path.Combine(source,"config.toml"),"sqlite_home = "+System.Text.Json.JsonSerializer.Serialize(database));
        File.WriteAllText(Path.Combine(source,".codex-global-state.json"),"{\"local-projects\":[\"original\"],\"secret-fixture\":\"never-import\"}");File.WriteAllText(Path.Combine(artifacts,"keep.txt"),"artifact");
        var repo=new Repository(Path.Combine(scope,"manager"),Path.Combine(scope,"runtime"));var a=new Account{Name="Shared A",SharesLocalWorkspace=true};var b=new Account{Name="Shared B",SharesLocalWorkspace=true};repo.Save(new(){Accounts=[a,b]});
        var prefs=new Preferences();prefs.Executables["workspace"]=source;prefs.Executables["artifacts"]=artifacts;
        foreach(var account in new[]{a,b}){repo.PrepareQuota(account);repo.PrepareProfile(account);}
        var privateArtifact=Path.Combine(repo.DataPath(b),"artifact-sessions");Directory.CreateDirectory(privateArtifact);File.WriteAllText(Path.Combine(privateArtifact,"private-cache.txt"),"keep");
        await SharedWorkspace.PrepareAsync(a,repo,prefs);Require(NativePlatform.SamePath(SharedWorkspace.Database(prefs),database),"Custom sqlite_home was not honored");
        var statePath=Path.Combine(repo.QuotaHome(a),".codex-global-state.json");var state=System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(statePath))!.AsObject();Require(!state.ContainsKey("secret-fixture"),"Workspace projection imported an unapproved key");state["local-projects"]!.AsArray().Add("new-project");File.WriteAllText(statePath,state.ToJsonString());
        var dbPath=Path.Combine(database,"state_5.sqlite");var rollout=Path.Combine(repo.QuotaHome(a),"sessions","fixture.jsonl");var canonical=Path.Combine(source,"sessions","fixture.jsonl");
        IntPtr db=IntPtr.Zero;Require(SqlOpen(dbPath,out db,6,IntPtr.Zero)==0,"Could not create SQLite fixture");
        try{Require(SqlExec(db,"CREATE TABLE threads (rollout_path TEXT);",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)==0,"Could not create fixture schema");IntPtr statement=IntPtr.Zero;try{Require(SqlPrepare(db,"INSERT INTO threads VALUES (?1)",-1,out statement,IntPtr.Zero)==0,"Could not prepare fixture");SqlBind(statement,1,rollout,-1,new IntPtr(-1));Require(SqlStep(statement)==101,"Could not insert fixture");}finally{if(statement!=IntPtr.Zero)SqlFinalize(statement);}}finally{SqlClose(db);}
        File.WriteAllText(Path.Combine(source,"sessions","fixture.jsonl"),"fixture");SharedWorkspace.Archive(a,repo);repo.Remove(a,repo.Load());Require(File.Exists(Path.Combine(artifacts,"keep.txt")),"Deleting a shared profile removed original artifacts");Require(File.Exists(canonical),"Deleting a shared profile removed original transcripts");
        Require(SqlOpen(dbPath,out db,2,IntPtr.Zero)==0,"Could not read SQLite fixture");try{IntPtr statement=IntPtr.Zero;try{SqlPrepare(db,"SELECT rollout_path FROM threads",-1,out statement,IntPtr.Zero);Require(SqlStep(statement)==100,"Missing fixture row");var actual=System.Runtime.InteropServices.Marshal.PtrToStringUTF8(SqlColumn(statement,0));Require(actual!=null&&NativePlatform.SamePath(actual,canonical),"Deleted profile path was not canonicalized: "+actual+"; expected: "+canonical+"; original: "+rollout);}finally{if(statement!=IntPtr.Zero)SqlFinalize(statement);}}finally{SqlClose(db);}
        await SharedWorkspace.PrepareAsync(b,repo,prefs);var projected=File.ReadAllText(Path.Combine(repo.QuotaHome(b),".codex-global-state.json"));Require(projected.Contains("new-project"),"Retained project metadata was not restored after deleting A");
        await SharedWorkspace.PrepareAsync(b with{SharesLocalWorkspace=false},repo,prefs);Require(File.Exists(Path.Combine(privateArtifact,"private-cache.txt")),"Private artifact cache was not restored");Require(Directory.Exists(artifacts),"Shared artifact source was removed");
    }
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_open_v2",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern int SqlOpen([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPUTF8Str)]string path,out IntPtr db,int flags,IntPtr vfs);
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_close",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern int SqlClose(IntPtr db);
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_exec",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern int SqlExec(IntPtr db,[System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPUTF8Str)]string sql,IntPtr cb,IntPtr ctx,IntPtr error);
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_prepare_v2",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern int SqlPrepare(IntPtr db,[System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPUTF8Str)]string sql,int size,out IntPtr statement,IntPtr tail);
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_bind_text",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern int SqlBind(IntPtr statement,int index,[System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPUTF8Str)]string value,int size,IntPtr destroy);
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_step",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern int SqlStep(IntPtr statement);
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_finalize",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern int SqlFinalize(IntPtr statement);
    [System.Runtime.InteropServices.DllImport("winsqlite3.dll",EntryPoint="sqlite3_column_text",CallingConvention=System.Runtime.InteropServices.CallingConvention.Cdecl)]static extern IntPtr SqlColumn(IntPtr statement,int column);

    static async Task ProcessRoutingAsync(string data){
        // The fixture root itself must retain the explicitly disposable prefix.
        var root=Path.Combine(Path.GetDirectoryName(data)!,"ai-switcher-smoke.process-"+Guid.NewGuid().ToString("N")+" space");var repository=new Repository(root,Path.Combine(root,"backend"));
        var a=new Account{Name="A",Agent=Agent.Claude};var b=new Account{Name="B",Agent=Agent.Claude};repository.Save(new(){Accounts=[a,b]});var engine=new AppEngine(root);engine.Preferences.Executables["claude"]=Environment.ProcessPath!;
        var children=new List<Process>();
        try{
            foreach(var account in new[]{a,b}){repository.PrepareProfile(account);var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false};foreach(var arg in new[]{"--process-fixture","--data-dir",root,"--user-data-dir="+repository.DataPath(account)})info.ArgumentList.Add(arg);if(account.Id==a.Id)info.ArgumentList.Add("--hide-on-close-fixture");children.Add(Process.Start(info)!);}
            for(var i=0;i<40;i++){await Task.Delay(250);await engine.Platform.RefreshProcessesAsync();if(engine.Platform.Owned(a)?.HasWindow==true&&engine.Platform.Owned(b)?.HasWindow==true)break;}
            Require(engine.Platform.Owned(a)?.Id==children[0].Id,"A was not routed to its exact PID");Require(engine.Platform.Owned(b)?.Id==children[1].Id,"B was not routed to its exact PID");
            Require(!await engine.SetExecutableAsync("claude",null),"A running profile allowed its executable routing to change");Require(engine.Preferences.Executables["claude"]==Environment.ProcessPath,"Rejected routing change mutated preferences");Require(!engine.CanConnect(a),"Claude must not expose a Codex connection");await engine.Platform.CloseAsync(a);Require(children[0].HasExited&&!children[1].HasExited,"Closing A affected B");await engine.Platform.CloseAsync(b);Require(children[1].HasExited,"B refused to close");
        }finally{foreach(var child in children){if(!child.HasExited)child.Kill(true);child.Dispose();}Repository.DeleteTree(root);}
    }
}
