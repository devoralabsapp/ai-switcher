using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static partial class PreviewRunner {
    static void AccountColumnsFixture(){
        var panel=new AccountColumnsPanel();
        foreach(var height in new[]{100,340,80,120,60})panel.Children.Add(new Border{Height=height});
        panel.Measure(new Size(790,double.PositiveInfinity));panel.Arrange(new Rect(0,0,790,panel.DesiredSize.Height));
        var next=System.Windows.Media.VisualTreeHelper.GetOffset(panel.Children[3]);
        Require(next.Y==114&&next.X==0,"A tall card pushed down the entire next row");
        panel.Measure(new Size(254,double.PositiveInfinity));panel.Arrange(new Rect(0,0,254,panel.DesiredSize.Height));
        Require(System.Windows.Media.VisualTreeHelper.GetOffset(panel.Children[1]).Y==114,"Single-column account layout overlapped cards");
    }
    static async Task WorkspaceActivationFixtureAsync(string parent,string cli){
        var root=Path.Combine(parent,"ai-switcher-smoke.activation-"+Guid.NewGuid().ToString("N"));var engine=new AppEngine(Path.Combine(root,"manager"));var repo=engine.Repository;
        var source=Path.Combine(root,"shared-workspace");Directory.CreateDirectory(source);engine.Preferences.Executables["workspace"]=source;
        var codexFixture=Path.Combine(Path.GetDirectoryName(cli)!,"codex-fixture.exe");File.Copy(cli,codexFixture,true);
        engine.Preferences.Executables["chatgpt"]=Environment.ProcessPath!;engine.Preferences.Executables["codex"]=codexFixture;
        var a=new Account{Name="Quota exhausted A",SharesLocalWorkspace=true};var b=new Account{Name="Available B",SharesLocalWorkspace=true};engine.SaveAccount(a);engine.SaveAccount(b);
        foreach(var account in new[]{a,b}){repo.PrepareProfile(account);repo.PrepareQuota(account);}
        var children=new List<Process>();
        Process Launch(Account account){
            var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false};foreach(var arg in new[]{"--process-fixture","--spawn-headless-fixture","--data-dir",root,"--user-data-dir="+repo.DataPath(account)})info.ArgumentList.Add(arg);
            var process=Process.Start(info)!;children.Add(process);return process;
        }
        async Task WaitRoot(Account account){for(var i=0;i<60;i++){await engine.Platform.RefreshProcessesAsync();if(engine.Platform.Owned(account)?.HasWindow==true){engine.Platform.SessionProcesses(account);return;}await Task.Delay(150);}throw new InvalidOperationException("Activation fixture window missing");}
        Process Helper(Process rootProcess){var child=Process.GetProcessById(int.Parse(File.ReadAllText(Path.Combine(root,"fixture-headless-"+rootProcess.Id+".pid"))));children.Add(child);return child;}
        try{
            var first=Launch(a);var stale=Launch(b);await WaitRoot(a);await WaitRoot(b);var oldHelper=Helper(stale);Helper(first);
            // B was connected before A exhausted quota. Switching must invalidate both
            // its Desktop client and the manager-owned RPC, even when B reports 100%.
            await engine.Backend.StartAsync(b);Require(engine.Backend.IsActive(b),"Fixture B backend was not connected");engine.RecordWorkspaceActivation(a);
            var sentinel=Path.Combine(repo.DataPath(b),"keep-login-and-history.txt");File.WriteAllText(sentinel,"preserved");
            await engine.PrepareWorkspaceActivationAsync(b);
            Require(stale.HasExited&&oldHelper.HasExited&&!engine.Backend.IsActive(b)&&!engine.Running(b),"Switch reused B's old Desktop/helper/RPC runtime");
            Require(!first.HasExited&&File.ReadAllText(sentinel)=="preserved","Switch modified another account or B storage");
            var renewed=Launch(b);await WaitRoot(b);Helper(renewed);engine.RecordWorkspaceActivation(b);await engine.PrepareWorkspaceActivationAsync(b);
            Require(!renewed.HasExited,"Opening the same current account unnecessarily restarted it");
            await engine.CloseAsync(a);Require(!engine.Errors.ContainsKey(a.Id),"Could not close previous shared account");
            await engine.PrepareWorkspaceActivationAsync(b);Require(renewed.HasExited,"Closing A did not invalidate a previously open B runtime");
            Require(File.ReadAllText(sentinel)=="preserved","Handoff lost B data");
        }finally{
            await engine.ShutdownAsync();foreach(var child in children){try{if(!child.HasExited){child.Kill(true);await child.WaitForExitAsync();}}finally{child.Dispose();}}
            foreach(var account in new[]{a,b})repo.Remove(account,repo.Load());
            Repository.DeleteTree(root);
        }
    }
}
