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
    public static int Run(string[] args){var root=Program.Argument(args,"--data-dir");var output=Program.Argument(args,"--output");var smoke=args.Contains("--ui-smoke-test");
        if(root==null||output==null||!Path.GetFileName(root).StartsWith(smoke?"ai-switcher-smoke.":"ai-switcher-preview.",StringComparison.Ordinal)||!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()),StringComparison.OrdinalIgnoreCase))return 2;
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/AISwitcher;component/Styles.xaml",UriKind.Relative)});int code=0;
        app.Startup+=async(_,_)=>{try{Directory.CreateDirectory(output);foreach(var language in new[]{"en","vi"})foreach(var theme in Themes.All){var data=Path.Combine(root,language,theme.Id);var repository=new Repository(data);repository.Save(Demo());var engine=new AppEngine(data);engine.Preferences.Language=language;engine.Preferences.Theme=theme.Id;
            var window=new MainWindow(engine){Width=1200,Height=950};window.Show();await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);window.UpdateLayout();Save(window,Path.Combine(output,$"{theme.Id}-{language}.png"));
            Require(Find(window,"addAccount") is Button,"Add account button missing");Require(Find(window,"quotaOnlyMode") is CheckBox,"Quota-only control missing");Require(Find(window,"agent-filter-claude") is Button,"Agent filter missing");
            engine.SetQuotaOnly(true);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.QuotaTable,"Quota-only must select table");engine.SetQuotaOnly(false);Require(engine.Preferences.WorkspaceLayout==WorkspaceLayout.Cards,"Disabling quota-only must restore cards");
            if(theme.Id=="terminalBlack"){Require(theme.Canvas=="#000000","Terminal Black canvas mismatch");engine.SetAgent(Agent.Claude);await CaptureDialog(window,()=>window.EditAccount(),Path.Combine(output,$"claude-editor-{language}.png"));await CaptureDialog(window,window.Settings,Path.Combine(output,$"settings-{language}.png"));}
            window.Exiting=true;window.Close();engine.Shutdown();
        }
        if(smoke)await ProcessRoutingAsync(Path.Combine(root,"processes"));
        File.WriteAllText(Path.Combine(output,"ui-smoke-result.txt"),"PASS: 7 themes × 2 languages; account/filter/quota controls; cards/table transition; Claude editor and settings rendering; exact native Windows fixture process routing.\n");
        }catch(Exception error){code=1;File.WriteAllText(Path.Combine(output,"ui-smoke-error.txt"),error.ToString());}finally{app.Shutdown(code);}};
        app.Run();return code;
    }
    static async Task CaptureDialog(MainWindow owner,Action open,string path){
        _=owner.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle,new Action(()=>{var dialog=Application.Current.Windows.Cast<Window>().FirstOrDefault(x=>x!=owner&&x.Owner==owner);if(dialog!=null){dialog.UpdateLayout();Save(dialog,path);dialog.Close();}}));open();await Task.CompletedTask;
    }
    static FrameworkElement? Find(DependencyObject root,string id){for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is FrameworkElement fe&&AutomationProperties.GetAutomationId(fe)==id)return fe;var found=Find(child,id);if(found!=null)return found;}return null;}
    static void Save(Window window,string path){var content=(FrameworkElement)window.Content;content.UpdateLayout();var width=(int)Math.Ceiling(content.ActualWidth);var height=(int)Math.Ceiling(content.ActualHeight);Require(width>0&&height>0,"Window did not render");var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);bitmap.Render(content);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(path);encoder.Save(stream);}
    static void Require(bool condition,string message){if(!condition)throw new InvalidOperationException(message);}
    static Snapshot Demo(){var limits=System.Text.Json.JsonSerializer.Deserialize<Limits>("{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":23,\"windowDurationMins\":300,\"resetsAt\":"+DateTimeOffset.UtcNow.AddHours(2).ToUnixTimeSeconds()+"},\"secondary\":{\"usedPercent\":41,\"windowDurationMins\":10080,\"resetsAt\":"+DateTimeOffset.UtcNow.AddDays(3).ToUnixTimeSeconds()+"}}}",Json.Options)!;
        return new(){Accounts=[new(){Name="Demo Personal",EmailHint="personal@example.test",Agent=Agent.Chatgpt,Color="mint",IsFavorite=true,DesktopConnection=new(new("demo@example.test","plus"),new(limits,DateTimeOffset.UtcNow))},new(){Name="Claude Work",EmailHint="work@example.test",Agent=Agent.Claude,Color="peach",IsFavorite=true},new(){Name="Claude Personal",Agent=Agent.Claude,LaunchMode=LaunchMode.Browser,Color="rose"},new(){Name="Gemini Study",Agent=Agent.Gemini,Color="blue"},new(){Name="Antigravity",Agent=Agent.Antigravity,Color="violet"},new(){Name="Perplexity Research",Agent=Agent.Perplexity,Color="mint"},new(){Name="DeepSeek Work",Agent=Agent.Deepseek,Color="gold"}]};}
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
