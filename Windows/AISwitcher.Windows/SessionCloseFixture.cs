using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static partial class PreviewRunner {
    static async Task SessionCloseFixtureAsync(string parent){
        var root=Path.Combine(parent,"ai-switcher-smoke.close-"+Guid.NewGuid().ToString("N"));var repo=new Repository(root);var a=new Account{Name="Close A"};var b=new Account{Name="Keep B"};repo.Save(new(){Accounts=[a,b]});var engine=new AppEngine(root);
        engine.Preferences.Executables["chatgpt"]=Environment.ProcessPath!;
        var started=new List<Process>();
        Process Launch(Account? account,string? mode=null){
            var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false};foreach(var value in new[]{"--process-fixture","--data-dir",root,"--user-data-dir="+(account==null?Path.Combine(root,"separate"):repo.DataPath(account))})info.ArgumentList.Add(value);if(mode!=null)info.ArgumentList.Add(mode);
            var process=Process.Start(info)!;started.Add(process);return process;
        }
        async Task Observe(){for(var i=0;i<60;i++){await engine.Platform.RefreshProcessesAsync();if(engine.Platform.Owned(a)?.HasWindow==true&&engine.Platform.Owned(b)?.HasWindow==true)return;await Task.Delay(150);}throw new InvalidOperationException("Fixture windows did not appear");}
        Process Backend(Process main){var pidFile=Path.Combine(root,"fixture-headless-"+main.Id+".pid");Require(File.Exists(pidFile),"Fixture did not spawn its headless backend");var process=Process.GetProcessById(int.Parse(File.ReadAllText(pidFile)));started.Add(process);return process;}
        try{
            foreach(var account in new[]{a,b}){repo.PrepareProfile(account);repo.PrepareQuota(account);}
            var keep=Launch(b);var separate=Launch(null);var main=Launch(a,"--spawn-headless-fixture");await Observe();var backend=Backend(main);
            for(var i=0;i<20&&!engine.Platform.SessionProcesses(a).Any(p=>p.Id==backend.Id);i++){await Task.Delay(150);await engine.Platform.RefreshProcessesAsync();}
            var seen=engine.Platform.Processes.FirstOrDefault(p=>p.Id==backend.Id);
            Require(engine.Platform.SessionProcesses(a).Any(p=>p.Id==backend.Id)&&seen!=null&&!seen.Arguments.Any(x=>x.StartsWith("--user-data-dir=")),"Headless fixture was not attributed exclusively through ancestry; root="+main.Id+"; child="+backend.Id+"; observed="+(seen==null?"missing":System.Text.Json.JsonSerializer.Serialize(seen))+"; root observed="+System.Text.Json.JsonSerializer.Serialize(engine.Platform.Owned(a)));
            var saved=Path.Combine(repo.DataPath(a),"persist.txt");File.WriteAllText(saved,"profile remains");
            Require(main.CloseMainWindow(),"Could not manually close the fixture root");await main.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));await engine.Platform.RefreshProcessesAsync();
            Require(!backend.HasExited&&engine.Platform.Owned(a)==null&&engine.Running(a)&&!engine.CanConnect(a)&&engine.Status(a)==engine.L["Running in background"],"Orphaned backend was mislabeled disconnected/connectable");
            await engine.CloseAsync(a);Require(!engine.Errors.ContainsKey(a.Id),"Close rejected its owned headless backend: "+engine.Errors.GetValueOrDefault(a.Id));Require(backend.HasExited&&!engine.Running(a)&&engine.CanConnect(a),"Close left the background backend running");
            Require(!keep.HasExited&&!separate.HasExited&&File.ReadAllText(saved)=="profile remains","Closing A changed B, another app or profile data");
            // This child is born during quit, after the final pre-close snapshot.
            var late=Launch(a,"--spawn-headless-on-exit-fixture");await Observe();await engine.CloseAsync(a);
            Require(!engine.Errors.ContainsKey(a.Id)&&late.HasExited,"Normal close did not finish its root: "+engine.Errors.GetValueOrDefault(a.Id));
            var latePid=int.Parse(File.ReadAllText(Path.Combine(root,"fixture-headless-"+late.Id+".pid")));
            Require(!engine.Platform.Processes.Any(p=>p.Id==latePid),"A backend born during quit survived the close action");
            Require(!keep.HasExited&&!separate.HasExited&&engine.CanConnect(a),"Late-child cleanup affected other profiles or Connect");
        }finally{
            foreach(var process in started){try{if(!process.HasExited){process.Kill(true);await process.WaitForExitAsync();}}finally{process.Dispose();}}
            foreach(var pidFile in Directory.GetFiles(root,"fixture-headless-*.pid")){var pid=int.Parse(File.ReadAllText(pidFile));try{using var process=Process.GetProcessById(pid);if(process.StartTime.ToUniversalTime().ToFileTimeUtc()==long.Parse(File.ReadAllText(pidFile+".created"),System.Globalization.CultureInfo.InvariantCulture)&&NativePlatform.SamePath(process.MainModule!.FileName!,Environment.ProcessPath!)){process.Kill();await process.WaitForExitAsync();}}catch(ArgumentException){}}
            engine.Shutdown();Repository.DeleteTree(root);
        }
    }
}
