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
    public static int Run(string[] args){var root=Program.Argument(args,"--data-dir");var output=Program.Argument(args,"--output");var smoke=args.Contains("--ui-smoke-test");var stdio=args.Contains("--stdio-smoke-test");var reopenStore=args.Contains("--store-runtime-reopen-smoke-test");var realStore=args.Contains("--store-runtime-smoke-test")||reopenStore;var backend=args.Contains("--backend-smoke-test")||stdio||realStore;
        if(root==null||output==null||!Path.GetFileName(root).StartsWith(smoke||backend?"ai-switcher-smoke.":"ai-switcher-preview.",StringComparison.Ordinal)||!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()),StringComparison.OrdinalIgnoreCase))return 2;
        if(realStore){try{Directory.CreateDirectory(output);RunStoreAsync(root,output,args,reopenStore).GetAwaiter().GetResult();return 0;}catch(Exception error){File.WriteAllText(Path.Combine(output,"store-runtime-error.txt"),error.ToString());return 1;}}
        if(backend){try{Directory.CreateDirectory(output);BackendFixtureAsync(root,output,Program.Argument(args,"--codex-executable")??throw new InvalidOperationException("Codex executable is required"),stdio).GetAwaiter().GetResult();File.WriteAllText(Path.Combine(output,"backend-smoke-result.txt"),stdio?"PASS: standalone EXE starts real native Windows Codex RPC in its own signed-out home; initialization and signed-out identity verified; managed connect/stop/reconnect; stale sockets ignored; two private backends force-stopped while another manager survives; no Desktop or real account.\n":"PASS: managed native Windows Codex RPC connects in its own signed-out home, restarts, stops and cleans up without a Desktop window or real account.\n");return 0;}catch(Exception error){File.AppendAllText(Path.Combine(output,"backend-smoke-error.txt"),error.ToString());return 1;}}
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/AISwitcher;component/Styles.xaml",UriKind.Relative)});int code=0;
        app.Startup+=async(_,_)=>{try{Directory.CreateDirectory(output);foreach(var language in new[]{"en","vi"})foreach(var theme in Themes.All){var data=Path.Combine(root,language,theme.Id);var repository=new Repository(data);repository.Save(Demo());var engine=new AppEngine(data);engine.Preferences.Language=language;engine.Preferences.Theme=theme.Id;
            var window=new MainWindow(engine){Width=1200,Height=950};window.Show();await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);window.UpdateLayout();Save(window,Path.Combine(output,$"{theme.Id}-{language}.png"));
            Require(Find(window,"addAccount") is Button,"Add account button missing");Require(Find(window,"quotaOnlyMode") is CheckBox,"Quota-only control missing");Require(Find(window,"agent-filter-claude") is Button,"Agent filter missing");Require(Find(window,"forceStopAll") is Button,"Force-stop control missing");CheckScrollbars(window);
            engine.SetQuotaOnly(true);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.QuotaTable,"Quota-only must select table");engine.SetQuotaOnly(false);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.Cards,"Disabling quota-only must restore cards");
            if(theme.Seasonal){await CaptureDialog(window,window.Settings,Path.Combine(output,$"settings-{theme.Id}-{language}.png"));}
            if(theme.Id=="terminalBlack"){Require(theme.Canvas=="#000000","Terminal Black canvas mismatch");engine.SetAgent(Agent.Claude);await CaptureDialog(window,()=>window.EditAccount(),Path.Combine(output,$"claude-editor-{language}.png"));await CaptureDialog(window,window.Settings,Path.Combine(output,$"settings-{language}.png"));}
            window.Exiting=true;window.Close();engine.Shutdown();
        }
        if(smoke){await ProviderFixtureAsync(root,Program.Argument(args,"--provider-cli-executable"));await ScrollbarFixtureAsync();ReadOnlyPreferences(root);await ProcessRoutingAsync(Path.Combine(root,"processes"));await WorkspaceFixtureAsync(root);}
        File.WriteAllText(Path.Combine(output,"ui-smoke-result.txt"),"PASS: 11 themes × 2 languages; account/filter/quota controls; cards/table transition; Claude editor and settings rendering; real provider CLI fixture processes for connect/read/disconnect/reconnect, identity mismatch and metadata retention; exact native Windows fixture process routing; private workspace junctions, custom database, metadata projection, SQLite path canonicalization and safe deletion.\n");
        }catch(Exception error){code=1;File.AppendAllText(Path.Combine(output,backend?"backend-smoke-error.txt":"ui-smoke-error.txt"),error.ToString());}finally{app.Shutdown(code);}};
        app.Run();return code;
    }
    static async Task ProviderFixtureAsync(string root,string? executable){
        Require(executable!=null&&File.Exists(executable),"Provider CLI test executable missing");
        var data=Path.Combine(root,"provider-sessions");var repo=new Repository(data);var claude=new Account{Name="Claude fixture",Agent=Agent.Claude,EmailHint="fixture@example.test"};var agy=new Account{Name="Antigravity fixture",Agent=Agent.Antigravity};repo.Save(new(){Accounts=[claude,agy]});
        var engine=new AppEngine(data);engine.Preferences.Executables["claudeCode"]=executable!;engine.Preferences.Executables["antigravityCli"]=executable!;
        Require(engine.CanConnect(claude)&&engine.CanConnect(agy),"Provider Connect disabled before connection");
        await engine.ConnectAsync(claude,false);Require(engine.Provider.Connected.Contains(claude.Id),"Claude control bridge did not connect: "+engine.Errors.GetValueOrDefault(claude.Id)+"; "+(File.Exists(Path.Combine(data,"provider-fixture-trace.txt"))?File.ReadAllText(Path.Combine(data,"provider-fixture-trace.txt")):"fixture did not start"));Require(!engine.CanConnect(claude),"Duplicate Claude Connect must be disabled");Require(engine.Snapshot.Accounts.First(x=>x.Id==claude.Id).Connection?.Quota?.Limits.Buckets.First().Value.Primary?.Remaining==0,"Claude 0% quota missing");
        await engine.ConnectAsync(agy,false);Require(engine.Provider.Connected.Contains(agy.Id),"Antigravity usage bridge did not connect: "+engine.Errors.GetValueOrDefault(agy.Id));Require(engine.Snapshot.Accounts.First(x=>x.Id==agy.Id).Connection?.Quota?.Limits.Buckets.First().Value.Primary?.Remaining==75,"Antigravity quota fraction is wrong");
        var edited=engine.Snapshot.Accounts.First(x=>x.Id==claude.Id) with{Name="Edited fixture"};Require(engine.SaveAccount(edited),"Cannot edit connected provider metadata");Require(engine.Snapshot.Accounts.First(x=>x.Id==claude.Id).Connection?.Quota!=null,"Editing dropped provider quota");
        await engine.CloseAsync(claude);await engine.CloseAsync(agy);Require(engine.CanConnect(claude)&&engine.CanConnect(agy),"Disconnect must restore Connect");
        var mismatch=engine.Snapshot.Accounts.First(x=>x.Id==claude.Id) with{EmailHint="other@example.test"};Require(engine.SaveAccount(mismatch),"Cannot set identity fixture");await engine.ConnectAsync(mismatch,false);Require(!engine.Provider.Connected.Contains(claude.Id),"Mismatched Claude identity was accepted");Require(engine.Errors.ContainsKey(claude.Id),"Mismatched identity must be visible");Require(engine.Snapshot.Accounts.First(x=>x.Id==claude.Id).Connection?.Quota!=null,"Failed read must preserve old quota");
        await engine.ShutdownAsync();
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
    static async Task CloseStoreAsync(AppEngine engine,Account account){
        await engine.Platform.CloseAsync(account);
        if(account.UsesCodexDesktop)await engine.Backend.StopAsync(account);
    }
    static async Task RunStoreAsync(string root,string output,string[] args,bool reopen){
        var source=Program.Argument(args,"--store-executable")??throw new InvalidOperationException("Store executable required");
        var agent=Program.Argument(args,"--store-agent")=="claude"?Agent.Claude:Agent.Chatgpt;
        if(reopen)await ReopenStoreAsync(root,output,source,agent);else await RealStoreAsync(root,output,source,agent);
    }
    static async Task ReopenStoreAsync(string root,string output,string source,Agent agent){
        var engine=new AppEngine(root);var repo=engine.Repository;var account=engine.Snapshot.Accounts.First();
        Require(account.Agent==agent,"Persisted profile agent changed");
        var sentinel=Path.Combine(repo.DataPath(account),"ai-switcher-reopen-fixture.txt");
        Require(File.ReadAllText(sentinel)==account.Id.ToString(),"Restart lost the existing profile data");
        var expected=WindowsExecutable.IsStorePath(source)?source:StoreRuntime.ExecutableFor(root,source);
        Require(NativePlatform.SamePath(engine.Preferences.Executables[agent.Name().ToLowerInvariant()],expected),"Restart lost the original executable selection");
        // Fallback extracted payloads also revalidate the persisted cache; registered Store installs go through OpenAsync below.
        if(!WindowsExecutable.IsStorePath(source))await StoreRuntime.PrepareAsync(root,source);
        var children=new List<int>();engine.Platform.FixtureStarted=pid=>children.Add(pid);
        try{
            await engine.Platform.OpenAsync(account,useLocalDaemon:false);
            var process=engine.Platform.Owned(account)??throw new InvalidOperationException("Restart did not open the saved account");
            await Task.Delay(5000);using(var opened=Process.GetProcessById(process.Id)){
                Require(!opened.HasExited,"Restarted runtime exited");var name=new System.Text.StringBuilder(128);GetClassName(opened.MainWindowHandle,name,128);
                Require(name.ToString().StartsWith("Chrome_WidgetWin_",StringComparison.Ordinal),"Restart showed a native error instead of the Desktop window");
            }
            Require(File.ReadAllText(sentinel)==account.Id.ToString(),"Opening after restart changed existing profile data");
            await CloseStoreAsync(engine,account);Require(engine.Platform.Owned(account)==null,"Restarted session did not quit");
            File.WriteAllText(Path.Combine(output,"store-runtime-reopen-result.txt"),"PASS: fresh AI Switcher EXE process reloads saved account/preferences, revalidates cached program files through the original Store executable, opens the same private profile with existing data intact, and closes normally.\n");
        }finally{
            engine.Shutdown();foreach(var pid in children){try{using var child=Process.GetProcessById(pid);if(!child.HasExited)child.Kill(true);await child.WaitForExitAsync();}catch(ArgumentException){}}
        }
    }
    static async Task RealStoreAsync(string root,string output,string source,Agent agent){
        var repo=new Repository(root);var a=new Account{Name="Store A",Agent=agent};var b=new Account{Name="Store B",Agent=agent};repo.Save(new(){Accounts=[a,b]});var engine=new AppEngine(root);var children=new List<int>();engine.Platform.FixtureStarted=pid=>children.Add(pid);Exception? failure=null;
        var runtime=await StoreRuntime.PrepareAsync(repo.Root,source);engine.Preferences.Executables[agent.Name().ToLowerInvariant()]=WindowsExecutable.IsStorePath(source)?source:runtime;
        if(agent==Agent.Chatgpt){engine.Preferences.Executables["codex"]=Path.Combine(Path.GetDirectoryName(runtime)!,"resources","codex.exe");Require(await CodexLocator.VerifyAsync(engine.Preferences.Executables["codex"]),"Copied native Store CLI did not run");}
        engine.SavePreferences();
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
            await CloseStoreAsync(engine,a);using(var other=Process.GetProcessById(children[1]))Require(!other.HasExited,"Closing hidden A affected B");
            Require(engine.Platform.Owned(a)==null,"Hidden A did not quit");
            await engine.Platform.OpenAsync(a,useLocalDaemon:false);Require(engine.Platform.Owned(a)?.Id!=oldA.Id,"Reopened A reused an exited process");
            await CloseStoreAsync(engine,a);await CloseStoreAsync(engine,b);
            var sentinel=Path.Combine(repo.DataPath(a),"ai-switcher-reopen-fixture.txt");File.WriteAllText(sentinel,a.Id.ToString());engine.Shutdown();
            var restart=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false};
            foreach(var argument in new[]{"--data-dir",root,"--output",output,"--store-runtime-reopen-smoke-test","--store-agent",agent==Agent.Claude?"claude":"chatgpt","--store-executable",source})restart.ArgumentList.Add(argument);
            using(var manager=Process.Start(restart)??throw new InvalidOperationException("Could not restart the test manager")){
                var wait=manager.WaitForExitAsync();if(await Task.WhenAny(wait,Task.Delay(TimeSpan.FromSeconds(120)))!=wait){manager.Kill(true);throw new InvalidOperationException("Restarted manager timed out");}
                Require(manager.ExitCode==0,"Fresh manager failed: "+(File.Exists(Path.Combine(output,"store-runtime-error.txt"))?File.ReadAllText(Path.Combine(output,"store-runtime-error.txt")):manager.ExitCode.ToString()));
            }
            Require(File.ReadAllText(sentinel)==a.Id.ToString(),"Fresh manager did not preserve the same profile");
            File.WriteAllText(Path.Combine(output,"store-runtime-result.txt"),"PASS: real official "+agent.Name()+" program files copied intact; two private profile windows/PIDs and user-data directories; existing A window reused; graceful close of hidden A preserves B; A reopens through original Store path; fresh AI Switcher process reloads the same saved profile and cache; both sessions quit without forced shutdown. Source: "+source+"\n");
        }catch(Exception error){failure=error;throw;}finally{
            foreach(var pid in children.Distinct()){try{using var child=Process.GetProcessById(pid);if(!child.HasExited)child.Kill(true);await child.WaitForExitAsync();}catch(ArgumentException){}}
            foreach(var account in new[]{a,b}){for(var attempt=0;attempt<75;attempt++){try{repo.Remove(account,repo.Load());break;}catch(IOException)when(attempt<74){await Task.Delay(400);}catch(Exception error)when(failure!=null){File.AppendAllText(Path.Combine(output,"store-runtime-cleanup.txt"),error.GetType().Name+"\n");break;}}}
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
            await using var client=await engine.Backend.StdioClientAsync(account);
            try{await client.ReadIdentityAsync();throw new InvalidOperationException("Fresh native Codex returned an existing identity");}catch(AppError error)when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){}
            await ManagedBackendFixtureAsync(engine,account,relocated,output);Require(!client.IsConnected,"Force stop left a temporary owned RPC process connected");
            return;
        }finally{await engine.Backend.StopAsync(account);repo.Remove(account,repo.Load());}}
        try{
            await engine.Backend.StartAsync(account);Require(engine.Backend.IsActive(account),"Native daemon was not active after connect");
            try{await engine.Backend.ReadAsync(account);throw new InvalidOperationException("A fresh profile unexpectedly returned a signed-in identity");}catch(AppError error)when(error.Key=="The Codex session is signed out or expired. Reconnect the account."){}
            var marker=Path.Combine(repo.QuotaHome(account),"smoke-persistence.txt");File.WriteAllText(marker,"fixture");await engine.Backend.StopAsync(account);await engine.Backend.StartAsync(account);Require(File.ReadAllText(marker)=="fixture","Backend restart did not preserve its own home");
            await engine.Platform.RefreshProcessesAsync();Require(engine.Platform.Owned(account)==null,"Headless connection unexpectedly opened a Desktop window");await engine.Backend.StopAsync(account);
        }finally{try{await engine.Backend.StopAsync(account);}finally{repo.Remove(account,repo.Load());}}
    }
    static async Task ScrollbarFixtureAsync(){
        var scroll=new ScrollViewer{VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,Content=new Border{Width=1400,Height=1400}};
        var window=new Window{Width=320,Height=240,Content=scroll};window.Show();
        try{
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);window.UpdateLayout();CheckScrollbars(window);
            var bars=Descendants(window).OfType<System.Windows.Controls.Primitives.ScrollBar>().ToArray();
            var vertical=bars.First(b=>b.Orientation==Orientation.Vertical);var horizontal=bars.First(b=>b.Orientation==Orientation.Horizontal);
            System.Windows.Controls.Primitives.ScrollBar.PageDownCommand.Execute(null,vertical);System.Windows.Controls.Primitives.ScrollBar.PageRightCommand.Execute(null,horizontal);
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);window.UpdateLayout();
            Require(scroll.VerticalOffset>0&&scroll.HorizontalOffset>0,"Themed scrollbar paging broke scrolling");
            var offset=scroll.VerticalOffset;scroll.LineDown();window.UpdateLayout();Require(scroll.VerticalOffset>offset,"Themed scrollbar broke line scrolling");
        }finally{window.Close();}
    }
    static void CheckScrollbars(DependencyObject root){
        foreach(var scroll in Descendants(root).OfType<System.Windows.Controls.Primitives.ScrollBar>()){
            scroll.ApplyTemplate();Require(scroll.Template.FindName("PART_Track",scroll) is System.Windows.Controls.Primitives.Track,"Themed scrollbar track is missing");
            Require(scroll.Template.FindName("Handle",scroll) is System.Windows.Controls.Primitives.Thumb,"Native scrollbar was not replaced by the themed thumb");
        }
    }
    static IEnumerable<DependencyObject> Descendants(DependencyObject root){for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);yield return child;foreach(var nested in Descendants(child))yield return nested;}}
    static async Task ManagedBackendFixtureAsync(AppEngine engine,Account a,string executable,string output){
        var repo=engine.Repository;var b=new Account{Name="Second managed backend"};engine.SaveAccount(b);repo.PrepareQuota(a);repo.PrepareProfile(a);
        var socket=engine.Backend.SocketPath(a);Directory.CreateDirectory(Path.GetDirectoryName(socket)!);File.WriteAllText(socket,"stale fixture, not a live daemon");
        Require(!engine.Running(a)&&engine.CanConnect(a)&&engine.Status(a)==engine.L["Disconnected"],"A stale socket blocked Connect or enabled Close");
        var other=new AppEngine(Path.Combine(repo.Root,"other-manager"));var outsider=new Account{Name="Separate manager"};other.SaveAccount(outsider);other.Preferences.Executables["codex"]=executable;
        var marker=Path.Combine(repo.QuotaHome(a),"keep-account-fixture.txt");File.WriteAllText(marker,"keep");
        try{
            await engine.ConnectAsync(a,false);Require(engine.Backend.IsActive(a)&&!engine.CanConnect(a),"Connect did not retain its own headless RPC process");
            Require(!engine.Errors.TryGetValue(a.Id,out var error)||error==engine.L["The Codex session is signed out or expired. Reconnect the account."],"Connect returned a daemon command failure");
            await engine.Backend.StartAsync(b);await other.Backend.StartAsync(outsider);
            await engine.ForceStopAllAsync();Require(!engine.Running(a)&&!engine.Running(b)&&engine.CanConnect(a),"Force stop left owned backends running");
            Require(File.ReadAllText(marker)=="keep","Force stop changed account data");Require(other.Backend.IsActive(outsider),"Force stop affected another manager's backend");
            var pending=engine.ConnectAsync(a,false);await engine.ForceStopAllAsync();await pending;
            Require(!engine.Running(a)&&engine.CanConnect(a),"Force stop racing with Connect left a backend running");
            await engine.Backend.StartAsync(a);Require(engine.Backend.IsActive(a),"Reconnect after force stop failed");await engine.Backend.StopAsync(a);
            await engine.Platform.RefreshProcessesAsync();Require(engine.Platform.Owned(a)==null,"Connecting quota opened a Desktop window");
            File.WriteAllText(Path.Combine(output,"managed-backend-result.txt"),"PASS: stale socket does not block Connect; the actual Connect action retains a native signed-out RPC session without Desktop/daemon startup; two owned backends stop; another manager's backend survives; data persists and reconnect works.\n");
        }finally{await engine.Backend.StopAsync(a);await engine.Backend.StopAsync(b);await other.Backend.StopAsync(outsider);repo.Remove(b,repo.Load());other.Repository.Remove(outsider,other.Repository.Load());}
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
        var root=Path.Combine(Path.GetDirectoryName(data)!,"ai-switcher-smoke.process-"+Guid.NewGuid().ToString("N")+" space");var repository=new Repository(root);
        var a=new Account{Name="A",Agent=Agent.Chatgpt};var b=new Account{Name="B",Agent=Agent.Claude};repository.Save(new(){Accounts=[a,b]});var engine=new AppEngine(root);
        engine.Preferences.Executables["claude"]=Environment.ProcessPath!;engine.Preferences.Executables["chatgpt"]=Environment.ProcessPath!;
        var children=new List<Process>();
        try{
            foreach(var account in new[]{a,b}){
                repository.PrepareProfile(account);var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false};
                foreach(var arg in new[]{"--process-fixture","--data-dir",root,"--user-data-dir="+repository.DataPath(account)})info.ArgumentList.Add(arg);
                if(account.Id==a.Id){info.ArgumentList.Add("--hide-on-close-fixture");info.ArgumentList.Add("--spawn-child-fixture");}children.Add(Process.Start(info)!);
            }
            var separate=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false};foreach(var arg in new[]{"--process-fixture","--data-dir",root,"--user-data-dir="+Path.Combine(root,"opened-separately")})separate.ArgumentList.Add(arg);children.Add(Process.Start(separate)!);
            for(var i=0;i<60;i++){await Task.Delay(250);await engine.Platform.RefreshProcessesAsync();if(engine.Platform.Owned(a)?.HasWindow==true&&engine.Platform.Owned(b)?.HasWindow==true&&engine.Platform.Processes.Any(p=>p.ParentId==children[0].Id))break;}
            Require(engine.Platform.Owned(a)?.Id==children[0].Id,"A was not routed to its exact PID");Require(engine.Platform.Owned(b)?.Id==children[1].Id,"B was not routed to its exact PID");
            Require(!await engine.SetExecutableAsync("claude",null),"A running profile allowed executable routing to change");Require(engine.Preferences.Executables["claude"]==Environment.ProcessPath,"Rejected routing change mutated preferences");
            var saved=Path.Combine(repository.DataPath(a),"preserved-fixture.txt");File.WriteAllText(saved,"keep");
            Require(children[0].CloseMainWindow(),"Could not manually close the hide-to-tray fixture");
            for(var i=0;i<40;i++){await Task.Delay(100);await engine.Platform.RefreshProcessesAsync();if(engine.Platform.Owned(a)?.HasWindow==false)break;}
            Require(engine.Running(a)&&engine.Status(a)==engine.L["Running in background"]&&!engine.CanConnect(a),"A hidden Desktop was mislabeled disconnected or enabled Connect");
            Require(children[1].CloseMainWindow(),"Could not manually close B");await children[1].WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));await engine.Platform.RefreshProcessesAsync();
            Require(!engine.Running(b)&&engine.Status(b)==engine.L["Disconnected"],"A manually exited Desktop stayed running");
            var nested=Process.GetProcessById(int.Parse(File.ReadAllText(Path.Combine(root,"fixture-child.pid"))));children.Add(nested);
            await engine.ForceStopAllAsync();
            Require(children[0].HasExited&&nested.HasExited,"Force stop left the hidden root or its verified child running");Require(!children[2].HasExited,"Force stop affected an app opened separately");Require(File.ReadAllText(saved)=="keep","Force stop changed profile data");
            Require(!engine.Running(a)&&engine.CanConnect(a)&&engine.Status(a)==engine.L["Disconnected"],"Force stop did not restore disconnected/connectable state");
        }finally{
            await engine.Platform.ForceStopAsync(a);await engine.Platform.ForceStopAsync(b);
            foreach(var child in children){if(!child.HasExited){child.Kill(true);await child.WaitForExitAsync();}child.Dispose();}Repository.DeleteTree(root);
        }
    }
}
