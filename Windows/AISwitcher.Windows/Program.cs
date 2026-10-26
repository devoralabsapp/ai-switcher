using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AISwitcher.Core;
using Forms=System.Windows.Forms;

namespace AISwitcher.Windows;
internal sealed class Program:Application {
    string traySignature="";
    FileStream? lease;SilentTrayIcon? tray;DispatcherTimer? timer;AppEngine? engine;MainWindow? manager;Guid? notificationAccount;
    [STAThread]public static int Main(string[] args){
        if(args.Contains("--process-fixture")){RunFixture(args);return 0;}
        if(args.Contains("--render-previews")||args.Contains("--ui-smoke-test")||args.Contains("--backend-smoke-test")||args.Contains("--stdio-smoke-test"))return PreviewRunner.Run(args);
        var app=new Program();app.Run();return 0;
    }
    protected override void OnStartup(StartupEventArgs e){base.OnStartup(e);ShutdownMode=ShutdownMode.OnExplicitShutdown;
        Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/AISwitcher;component/Styles.xaml",UriKind.Relative)});
        var root=Argument(e.Args,"--data-dir")??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"AISwitcher");
        var message=RegisterWindowMessage("AISwitcher.Show."+Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(root)))));
        try{var repository=new Repository(root);NativePlatform.ProtectDirectory(repository.Root);lease=repository.AcquireLease();}
        catch(IOException){PostMessage(new IntPtr(0xffff),message,IntPtr.Zero,IntPtr.Zero);Shutdown();return;}
        catch{MessageBox.Show("AI Switcher could not open its data directory. Existing data was preserved.","AI Switcher");Shutdown(1);return;}
        engine=new(root);manager=new(engine);MainWindow=manager;
        manager.SourceInitialized+=(_,_)=>{
            var source=HwndSource.FromHwnd(new WindowInteropHelper(manager).Handle);source?.AddHook((IntPtr hwnd,int msg,IntPtr w,IntPtr l,ref bool handled)=>{if((uint)msg==message){manager.ShowManager();handled=true;}return IntPtr.Zero;});
        };
        tray=new SilentTrayIcon{Text="AI Switcher",Visible=true,Icon=System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!)??System.Drawing.SystemIcons.Application};
        tray.DoubleClick+=(_,_)=>Dispatcher.Invoke(manager.ShowManager);tray.BalloonTipClicked+=(_,_)=>Dispatcher.Invoke(()=>{if(engine.Snapshot.Accounts.FirstOrDefault(x=>x.Id==notificationAccount) is { } a)manager.QuotaDetails(a);});
        engine.Changed+=RebuildTray;engine.QuotaAlert+=(account,alerts)=>{
            notificationAccount=account.Id;var lines=string.Join("\n",alerts.Select(x=>engine.L[x.Recovered?"Quota recovered":"Low quota"]+": "+x.Remaining.ToString("0.#",engine.L.Culture)+"%"));tray.ShowBalloonTip(5000,account.Name,lines,Forms.ToolTipIcon.Info);
        };
        RebuildTray();if(!e.Args.Contains("--tray"))manager.Show();else{manager.Show();manager.Hide();}
        timer=new DispatcherTimer{Interval=TimeSpan.FromSeconds(3)};timer.Tick+=async(_,_)=>await engine.ObserveAsync();timer.Start();_=engine.InitializeAsync();
        manager.CommandBindings.Add(new System.Windows.Input.CommandBinding(System.Windows.Input.ApplicationCommands.Close,(_,_)=>manager.Hide()));
    }
    void RebuildTray(){if(engine==null||tray==null||manager==null)return;
        var next=System.Text.Json.JsonSerializer.Serialize(engine.Snapshot,Json.Options)+System.Text.Json.JsonSerializer.Serialize(engine.Preferences,Json.Options)+string.Join("|",engine.Snapshot.Accounts.Select(a=>engine.Status(a)));
        if(next==traySignature)return;traySignature=next;var l=engine.L;var menu=new Forms.ContextMenuStrip();
        menu.Items.Add(l["Show manager"],null,(_,_)=>Dispatcher.Invoke(manager.ShowManager));menu.Items.Add(new Forms.ToolStripSeparator());
        foreach(var account in engine.Snapshot.Accounts){var a=account;var item=new Forms.ToolStripMenuItem(a.Agent.Name()+" · "+a.Name);var status=new Forms.ToolStripMenuItem(engine.Status(a)){Enabled=false};item.DropDownItems.Add(status);
            if(a.Connection?.Quota is { } quota){if(quota.IsStale(DateTimeOffset.UtcNow)||engine.Errors.ContainsKey(a.Id))item.DropDownItems.Add(new Forms.ToolStripMenuItem(l["Stale data · refresh needed"]){Enabled=false});foreach(var b in quota.Limits.Buckets){item.DropDownItems.Add(new Forms.ToolStripMenuItem(b.Value.LimitName??b.Key){Enabled=false});foreach(var w in new[]{b.Value.Primary,b.Value.Secondary}.OfType<QuotaWindow>()){var value=!w.Expired(DateTimeOffset.UtcNow)?w.Remaining:null;item.DropDownItems.Add(new Forms.ToolStripMenuItem(w.Duration(l)+": "+(value.HasValue?value.Value.ToString("0.#",l.Culture)+"%":l["No data yet"])){Enabled=false});if(w.Reset is { } reset)item.DropDownItems.Add(new Forms.ToolStripMenuItem(l.Format("Reset: %@",l.Date(reset))){Enabled=false});}}item.DropDownItems.Add(new Forms.ToolStripMenuItem(l.Format("Last read: %@",l.Date(quota.FetchedAt))){Enabled=false});}
            void Action(string text,Action action,bool enabled=true){var button=new Forms.ToolStripMenuItem(text){Enabled=enabled};button.Click+=(_,_)=>Dispatcher.Invoke(action);item.DropDownItems.Add(button);}
            item.DropDownItems.Add(new Forms.ToolStripSeparator());Action(engine.DefaultTitle(a),()=>_=engine.DefaultAsync(a),!engine.Busy.Contains(a.Id));
            if(a.UsesCodexDesktop){Action(l["Open ChatGPT Desktop"],()=>_=engine.OpenAsync(a),!engine.Busy.Contains(a.Id));Action(l["Connect account session"],()=>_=engine.ConnectAsync(a),engine.CanConnect(a));}
            if(a.Agent.HasQuota()){Action(l["Refresh quota"],()=>_=engine.RefreshAsync(a),!engine.Busy.Contains(a.Id)&&(a.UsesCodexDesktop||a.BrowserConnection!=null));Action(l["Details"],()=>manager.QuotaDetails(a));}
            Action(l["Close account session…"],()=>manager.Close(a),!a.Agent.IsShared()&&engine.Running(a)&&!engine.Busy.Contains(a.Id));menu.Items.Add(item);
        }
        menu.Items.Add(new Forms.ToolStripSeparator());menu.Items.Add(l["Add account…"],null,(_,_)=>Dispatcher.Invoke(()=>manager.EditAccount()));menu.Items.Add(l["Appearance & Language"],null,(_,_)=>Dispatcher.Invoke(manager.Settings));menu.Items.Add(l["Session diagnostics"],null,(_,_)=>Dispatcher.Invoke(manager.Diagnostics));menu.Items.Add(l["Quit AI Switcher"],null,(_,_)=>Dispatcher.Invoke(()=>{manager.Exiting=true;engine.Shutdown();Shutdown();}));
        var old=tray.ContextMenuStrip;tray.ContextMenuStrip=menu;old?.Dispose();
    }
    protected override void OnExit(ExitEventArgs e){timer?.Stop();engine?.Shutdown();tray?.Dispose();lease?.Dispose();base.OnExit(e);}
    public static string? Argument(string[] args,string key){var i=Array.IndexOf(args,key);return i>=0&&i+1<args.Length?args[i+1]:null;}
    static void RunFixture(string[] args){var root=Argument(args,"--data-dir");var profile=args.FirstOrDefault(x=>x.StartsWith("--user-data-dir=",StringComparison.Ordinal));
        if(root==null||!Path.GetFileName(root).StartsWith("ai-switcher-smoke.",StringComparison.Ordinal)||profile==null||!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()),StringComparison.OrdinalIgnoreCase))return;
        var app=new Application();var window=new Window{Title="AI Switcher disposable profile fixture",Width=400,Height=250,Content=new System.Windows.Controls.TextBlock{Text="Disposable Windows process fixture",Margin=new Thickness(25)}};app.Run(window);
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern uint RegisterWindowMessage(string value);
    [DllImport("user32.dll")]static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr wParam,IntPtr lParam);
}
