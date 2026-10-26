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
    public static int Run(string[] args){var root=Program.Argument(args,"--data-dir");var output=Program.Argument(args,"--output");var smoke=args.Contains("--ui-smoke-test");var backend=args.Contains("--backend-smoke-test");
        if(root==null||output==null||!Path.GetFileName(root).StartsWith(smoke||backend?"ai-switcher-smoke.":"ai-switcher-preview.",StringComparison.Ordinal)||!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()),StringComparison.OrdinalIgnoreCase))return 2;
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/AISwitcher;component/Styles.xaml",UriKind.Relative)});int code=0;
        app.Startup+=async(_,_)=>{try{Directory.CreateDirectory(output);if(backend){await BackendFixtureAsync(root,output,Program.Argument(args,"--codex-executable")??throw new InvalidOperationException("Codex executable is required"));File.WriteAllText(Path.Combine(output,"backend-smoke-result.txt"),"PASS: native Windows Codex daemon starts, accepts a local authenticated-transport handshake in its own signed-out home, restarts, stops and cleans up without a Desktop window or real account.\n");return;}foreach(var language in new[]{"en","vi"})foreach(var theme in Themes.All){var data=Path.Combine(root,language,theme.Id);var repository=new Repository(data);repository.Save(Demo());var engine=new AppEngine(data);engine.Preferences.Language=language;engine.Preferences.Theme=theme.Id;
            var window=new MainWindow(engine){Width=1200,Height=950};window.Show();await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);window.UpdateLayout();Save(window,Path.Combine(output,$"{theme.Id}-{language}.png"));
            Require(Find(window,"addAccount") is Button,"Add account button missing");Require(Find(window,"quotaOnlyMode") is CheckBox,"Quota-only control missing");Require(Find(window,"agent-filter-claude") is Button,"Agent filter missing");
            engine.SetQuotaOnly(true);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.QuotaTable,"Quota-only must select table");engine.SetQuotaOnly(false);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.Cards,"Disabling quota-only must restore cards");
            if(theme.Id=="terminalBlack"){Require(theme.Canvas=="#000000","Terminal Black canvas mismatch");engine.SetAgent(Agent.Claude);await CaptureDialog(window,()=>window.EditAccount(),Path.Combine(output,$"claude-editor-{language}.png"));await CaptureDialog(window,window.Settings,Path.Combine(output,$"settings-{language}.png"));}
            window.Exiting=true;window.Close();engine.Shutdown();
        }
        if(smoke){await ProcessRoutingAsync(Path.Combine(root,"processes"));await WorkspaceFixtureAsync(root);}
        File.WriteAllText(Path.Combine(output,"ui-smoke-result.txt"),"PASS: 7 themes × 2 languages; account/filter/quota controls; cards/table transition; Claude editor and settings rendering; exact native Windows fixture process routing; private workspace junctions, custom database, metadata projection, SQLite path canonicalization and safe deletion.\n");
        }catch(Exception error){code=1;File.AppendAllText(Path.Combine(output,backend?"backend-smoke-error.txt":"ui-smoke-error.txt"),error.ToString());}finally{app.Shutdown(code);}};
        app.Run();return code;
    }
    static async Task CaptureDialog(MainWindow owner,Action open,string path){
        _=owner.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle,new Action(()=>{var dialog=Application.Current.Windows.Cast<Window>().FirstOrDefault(x=>x!=owner&&x.Owner==owner);if(dialog!=null){dialog.UpdateLayout();Save(dialog,path);dialog.Close();}}));open();await Task.CompletedTask;
    }
    static FrameworkElement? Find(DependencyObject root,string id){for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is FrameworkElement fe&&AutomationProperties.GetAutomationId(fe)==id)return fe;var found=Find(child,id);if(found!=null)return found;}return null;}
    static void Save(Window window,string path){window.UpdateLayout();var width=(int)Math.Ceiling(window.ActualWidth);var height=(int)Math.Ceiling(window.ActualHeight);Require(width>0&&height>0,"Window did not render");var background=new DrawingVisual();using(var draw=background.RenderOpen())draw.DrawRectangle(window.Background??Brushes.White,null,new Rect(0,0,width,height));var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);bitmap.Render(background);bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(path);encoder.Save(stream);}


    static void Require(bool condition,string message){if(!condition)throw new InvalidOperationException(message);}
    static Snapshot Demo(){var limits=System.Text.Json.JsonSerializer.Deserialize<Limits>("{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":23,\"windowDurationMins\":300,\"resetsAt\":"+DateTimeOffset.UtcNow.AddHours(2).ToUnixTimeSeconds()+"},\"secondary\":{\"usedPercent\":41,\"windowDurationMins\":10080,\"resetsAt\":"+DateTimeOffset.UtcNow.AddDays(3).ToUnixTimeSeconds()+"}}}",Json.Options)!;
        return new(){Accounts=[new(){Name="Demo Personal",EmailHint="personal@example.test",Agent=Agent.Chatgpt,Color="mint",IsFavorite=true,DesktopConnection=new(new("demo@example.test","plus"),new(limits,DateTimeOffset.UtcNow))},new(){Name="Claude Work",EmailHint="work@example.test",Agent=Agent.Claude,Color="peach",IsFavorite=true},new(){Name="Claude Personal",Agent=Agent.Claude,LaunchMode=LaunchMode.Browser,Color="rose"},new(){Name="Gemini Study",Agent=Agent.Gemini,Color="blue"},new(){Name="Antigravity",Agent=Agent.Antigravity,Color="violet"},new(){Name="Perplexity Research",Agent=Agent.Perplexity,Color="mint"},new(){Name="DeepSeek Work",Agent=Agent.Deepseek,Color="gold"}]};}
    static async Task BackendFixtureAsync(string root,string output,string executable){
        var account=new Account{Name="Native backend smoke"};var repo=new Repository(root);repo.Save(new(){Accounts=[account]});var engine=new AppEngine(root);engine.Preferences.Executables["codex"]=executable;engine.Backend.FixtureDiagnostic=text=>File.AppendAllText(Path.Combine(output,"backend-smoke-error.txt"),text+"\n");
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
            foreach(var account in new[]{a,b}){repository.PrepareProfile(account);var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false};foreach(var arg in new[]{"--process-fixture","--data-dir",root,"--user-data-dir="+repository.DataPath(account)})info.ArgumentList.Add(arg);children.Add(Process.Start(info)!);}
            for(var i=0;i<40;i++){await Task.Delay(250);await engine.Platform.RefreshProcessesAsync();if(engine.Platform.Owned(a)?.HasWindow==true&&engine.Platform.Owned(b)?.HasWindow==true)break;}
            Require(engine.Platform.Owned(a)?.Id==children[0].Id,"A was not routed to its exact PID");Require(engine.Platform.Owned(b)?.Id==children[1].Id,"B was not routed to its exact PID");
            Require(!engine.CanConnect(a),"Claude must not expose a Codex connection");await engine.Platform.CloseAsync(a);Require(children[0].HasExited&&!children[1].HasExited,"Closing A affected B");await engine.Platform.CloseAsync(b);Require(children[1].HasExited,"B refused to close");
        }finally{foreach(var child in children){if(!child.HasExited)child.Kill(true);child.Dispose();}Repository.DeleteTree(root);}
    }
}
