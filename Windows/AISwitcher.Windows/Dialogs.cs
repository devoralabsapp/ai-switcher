using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using AISwitcher.Core;
using static AISwitcher.Windows.ThemeManager;

namespace AISwitcher.Windows;
internal sealed partial class MainWindow {
    Window Dialog(string title,double width=560,double height=600){var window=new Window{Owner=this,Title=title,Width=width,Height=height,MinWidth=width,MinHeight=350,WindowStartupLocation=WindowStartupLocation.CenterOwner,ShowInTaskbar=false};window.SourceInitialized+=(_,_)=>ThemeManager.ApplyChrome(window,T);return window;}
    public void Notice(string title,string text){var dialog=Dialog(title,550,330);var close=Button(L["Got it"],()=>dialog.Close(),true,T);dialog.Content=new Border{Padding=new Thickness(24),Child=Stack(Text(title,22,true),Space(16),new ScrollViewer{Content=Text(text,13),MaxHeight=155},Space(18),close)};dialog.ShowDialog();}
    bool Ask(string title,string message,string confirm){var dialog=Dialog(title,560,350);var yes=Button(confirm,()=>dialog.DialogResult=true,true,T);var cancel=Button(L["Cancel"],()=>dialog.DialogResult=false);dialog.Content=new Border{Padding=new Thickness(24),Child=Stack(Text(title,21,true),Space(18),new ScrollViewer{Content=Text(message),MaxHeight=170},Space(22),Row(cancel,yes))};return dialog.ShowDialog()==true;}
    public void QuotaDetails(Account account){ShowManager();var dialog=Dialog(account.Agent.ProviderQuota()?L.Format("%@ quota",account.Agent.Name()):L["Codex quota"],590,680);void Build(){var a=engine.Snapshot.Accounts.FirstOrDefault(x=>x.Id==account.Id);if(a==null){dialog.Close();return;}
        var stack=Stack(Text(a.Name,23,true),Space(5),Text(a.Agent.Name()+" · "+engine.Status(a),12,false,T.Secondary),Space(20));
        if(!a.Agent.HasQuota()){stack.Children.Add(Text(Support(a)));stack.Children.Add(Space(20));stack.Children.Add(Button(L.Format("Open %@",a.Agent.Name()),()=>_=engine.OpenAsync(a),true,T));}
        else{
            stack.Children.Add(QuotaSummary(a,true));
            stack.Children.Add(Space(18));
            if(a.Agent.ProviderQuota()){
                var connect=Button(L["Connect account session"],async()=>{await engine.ConnectAsync(a);Build();},true,T);connect.IsEnabled=engine.CanConnect(a);stack.Children.Add(connect);
                if(a.Agent!=Agent.Antigravity&&!a.UsesClaudeDesktopQuota){stack.Children.Add(Button(L["Sign in with official CLI…"],()=>{try{engine.Provider.SignIn(a);}catch(Exception error){Notice(L["AI Switcher"],engine.Message(error));}}));}
                if(a.UsesProviderCli)AddProviderInstallation(stack,a,Build);
                if(a.Agent!=Agent.Antigravity&&engine.Provider.Connected.Contains(a.Id))stack.Children.Add(Button(L["Disconnect"],async()=>{await engine.CloseAsync(a);Build();}));
                if(engine.WaitingForSignIn.Contains(a.Id))stack.Children.Add(Button(L["Cancel"],()=>{engine.CancelConnection(a);Build();}));
            }
            else if(a.UsesCodexDesktop){var connect=Button(L["Connect account session"],async()=>{await engine.ConnectAsync(a);Build();},true,T);connect.IsEnabled=engine.CanConnect(a);stack.Children.Add(connect);stack.Children.Add(Space(8));stack.Children.Add(Button(L["Open ChatGPT Desktop"],async()=>{await engine.OpenAsync(a);Build();}));}
            else{stack.Children.Add(Text(L["Browser quota is a separate Codex sign-in. Verify its email before using it."]));stack.Children.Add(Space(12));var connect=Button(L["Connect Codex…"],async()=>{await BrowserLogin(a);Build();},true,T);connect.IsEnabled=!engine.Busy.Contains(a.Id);stack.Children.Add(connect);if(a.BrowserConnection!=null)stack.Children.Add(Button(L["Disconnect"],async()=>{if(Ask(L["Disconnect Codex?"],L["This removes this profile's separate Codex sign-in and cached quota."],L["Disconnect"])){await engine.DisconnectBrowserAsync(a);Build();}}));}
            var refresh=Button(L["Refresh quota"],async()=>{await engine.RefreshAsync(a);Build();});refresh.IsEnabled=!engine.Busy.Contains(a.Id)&&(a.Agent.ProviderQuota()||a.UsesCodexDesktop||a.BrowserConnection!=null);stack.Children.Add(Space(10));stack.Children.Add(refresh);
        }
        stack.Children.Add(Space(22));stack.Children.Add(Button(L["Done"],()=>dialog.Close()));dialog.Content=new ScrollViewer{Content=new Border{Padding=new Thickness(26),Child=stack},VerticalScrollBarVisibility=ScrollBarVisibility.Auto};}
        Build();dialog.ShowDialog();}
    async Task BrowserLogin(Account a){using var cancellation=new CancellationTokenSource();var progress=Dialog(L["Connect Codex…"],500,260);
        progress.Content=new Border{Padding=new Thickness(24),Child=Stack(Text(L["Waiting for sign-in…"],19,true),Space(14),Text(L["Sign in to Codex in this profile's browser window, then verify the returned account identity."]),Space(20),Button(L["Cancel"],()=>cancellation.Cancel()))};progress.Closing+=(_,_)=>cancellation.Cancel();progress.Show();
        try{await engine.BrowserLoginAsync(a,identity=>{progress.Hide();return Task.FromResult(Ask(L["Verify Codex account"],(identity.Email??L["No data yet"])+"\n"+(identity.PlanType??"")+"\n\n"+L["Use this Codex account for this profile?"],L["Use this account"]));},cancellation.Token);}finally{progress.Close();}
    }
    public void EditAccount(Account? original=null){ShowManager();var dialog=Dialog(L[original==null?"Add account":"Edit profile"],550,760);
        var name=new TextBox{Text=original?.Name??"",MaxLength=48};var note=new TextBox{Text=original?.EmailHint??"",MaxLength=160};
        var agentValues=Enum.GetValues<Agent>();var agent=new ComboBox{ItemsSource=agentValues.Select(x=>x.Name()).ToArray(),SelectedIndex=Array.IndexOf(agentValues,original?.Agent??engine.Preferences.AgentFilter??Agent.Chatgpt),IsEnabled=original==null};System.Windows.Automation.AutomationProperties.SetAutomationId(agent,"accountAgent");
        var browser=new ComboBox{ItemsSource=Enum.GetValues<Browser>(),SelectedItem=original?.Browser??Browser.Chrome,IsEnabled=original==null};
        var desktopSignIn=new ComboBox{ItemsSource=new[]{L["Sign in with browser"],L["Sign in with Desktop app"],L["Sign in with CLI"]},SelectedIndex=(int)(original?.EffectiveSignInMethod??AccountSignInMethod.Browser)};System.Windows.Automation.AutomationProperties.SetAutomationId(desktopSignIn,"accountSignInMethod");
        var color=new ComboBox{ItemsSource=ProfileColors.Names.Select(x=>L[char.ToUpperInvariant(x[0])+x[1..]]).ToArray(),SelectedIndex=original==null?engine.Snapshot.Accounts.Count%ProfileColors.Names.Length:Array.IndexOf(ProfileColors.Names,original.Color)};
        var defaultAction=new ComboBox{ItemsSource=new[]{L["Open ChatGPT"],L["Connect in background"]},SelectedIndex=original?.DefaultAction==DefaultAction.ConnectSession||original==null&&engine.Preferences.QuotaOnlyMode?1:0};
        var startup=new CheckBox{Content=L["Connect in background when AI Switcher starts"],IsChecked=original?.ConnectOnStartup??false};
        var shared=new CheckBox{Content=L["Share local projects and Work history"],IsChecked=original?.SharesLocalWorkspace??false};
        var signInMethod=new ComboBox{ItemsSource=new[]{L["Sign in with browser"],L["Sign in with Antigravity CLI"]},SelectedIndex=original?.AntigravitySignInMethod==AntigravitySignInMethod.Cli?1:0};System.Windows.Automation.AutomationProperties.SetAutomationId(signInMethod,"antigravitySignInMethod");
        var shareAntigravityProject = new CheckBox { Content = L["Share local project"], IsChecked = original?.SharesAntigravityProjects ?? false };
        System.Windows.Automation.AutomationProperties.SetAutomationId(shareAntigravityProject, "antigravityShareLocalProject");
        var projectEditor = Stack(shareAntigravityProject,
            Text(L["Share all local projects and conversation history from Antigravity Desktop. Close shared sessions before switching accounts."], 11, false, T.Secondary));
        var projectLocked = Text(L["Close the session from the ⋯ menu and wait for quota operations to finish before changing modes."], 11, false, T.Secondary);
        var antigravityProjectOptions = Stack(projectEditor, projectLocked, Space(16));
        var openAfter=new CheckBox{Content=L["Open after adding"],IsChecked=!engine.Preferences.QuotaOnlyMode};
        var explanation=Text("",11,false,T.Secondary);var fields=new StackPanel();
        StackPanel Field(string label,UIElement content){var group=Stack(Text(L[label],12,true),Space(6),content,Space(16));fields.Children.Add(group);return group;}
        Field("AI agent",agent);Field("Account name",name);Field("Email or note",note);Field("Profile color",color);var modeField=Field("Sign-in Method",desktopSignIn);fields.Children.Add(explanation);fields.Children.Add(Space(14));var browserField=Field("Browser",browser);
        var desktopOptions=Stack(Text(L["Default account action"],12,true),Space(6),defaultAction,startup,shared,Text(L["Sharing uses the workspace folder selected in Settings. Authentication stays private."],11,false,T.Secondary),Space(16));fields.Children.Add(desktopOptions);
        var signInField=Field("Sign-in method",signInMethod);
        var browserSignInHint = Text(L["After Google confirms sign-in, return to AI Switcher and choose Open Antigravity."], 11, false, T.Secondary);
        fields.Children.Add(browserSignInHint);
        fields.Children.Add(antigravityProjectOptions);
        if(original==null)fields.Children.Add(openAfter);
        var support=Text(L["Sign in directly with the selected agent. AI Switcher does not read passwords, cookies, or conversations."],11,false,T.Secondary);support.Margin=new Thickness(0,16,0,20);fields.Children.Add(support);
        void UpdateFields(){var selected=agentValues[agent.SelectedIndex];var selectedMode=LaunchMode.Desktop;
            support.Text=L[selected==Agent.Claude?"Claude quota reads only this profile's Desktop session cookie to request account and usage data from claude.ai. It does not read conversations or copy cookies into account metadata or logs.":"Sign in directly with the selected agent. AI Switcher does not read passwords, cookies, or conversations."];
            desktopSignIn.IsEnabled=(selected is Agent.Chatgpt or Agent.Claude)&&(original==null||!engine.Running(original)&&!engine.Busy.Contains(original.Id));
            var effective=selected is Agent.Chatgpt or Agent.Claude?selectedMode:selected.IsShared()?LaunchMode.Desktop:LaunchMode.Browser;
            modeField.Visibility=selected is Agent.Claude or Agent.Chatgpt?Visibility.Visible:Visibility.Collapsed;browserField.Visibility=effective==LaunchMode.Browser?Visibility.Visible:Visibility.Collapsed;desktopOptions.Visibility=selected==Agent.Chatgpt&&effective==LaunchMode.Desktop?Visibility.Visible:Visibility.Collapsed;
            signInField.Visibility=selected==Agent.Antigravity&&original==null?Visibility.Visible:Visibility.Collapsed;
            browserSignInHint.Visibility = signInField.Visibility == Visibility.Visible && signInMethod.SelectedIndex == 0
                ? Visibility.Visible : Visibility.Collapsed;
            antigravityProjectOptions.Visibility = selected == Agent.Antigravity && (original == null || original.UsesPrivateAntigravity)
                ? Visibility.Visible : Visibility.Collapsed;
            projectEditor.IsEnabled = original == null || (!engine.Running(original) && !engine.Busy.Contains(original.Id));
            projectLocked.Visibility = projectEditor.IsEnabled ? Visibility.Collapsed : Visibility.Visible;
            openAfter.Content=L[selected is Agent.Antigravity or Agent.Chatgpt or Agent.Claude?"Sign in after adding":"Open after adding"];
            shared.IsEnabled=original==null||!engine.Running(original);
            if(selected is Agent.Chatgpt or Agent.Claude) {
                var method=(AccountSignInMethod)desktopSignIn.SelectedIndex;
                var detail=selected==Agent.Claude&&method==AccountSignInMethod.Cli
                    ? "Claude CLI signs in to Claude Code only. Sign in to Claude Desktop once too; quota is read from Desktop, including Free when Claude provides it."
                    : selected==Agent.Claude&&method==AccountSignInMethod.Browser
                    ? "In this account's Claude Desktop window, choose browser sign-in and finish authorization in your browser. The saved session belongs to Desktop."
                    : selected==Agent.Chatgpt&&method==AccountSignInMethod.Browser
                    ? "Authorize in your existing Chrome, then return to this account's ChatGPT Desktop session."
                    : "Sign in directly in this account's Desktop window.";
                explanation.Text=L["All sign-in methods open the Desktop app. Each account keeps its own saved session."]+"\n"+L[detail];
                if(original!=null)explanation.Text+="\n"+L["To sign in again, close the session, then choose Sign in… in the account menu."];
                if(original?.EffectiveMode==LaunchMode.Browser)explanation.Text+="\n"+L["Existing browser sign-ins stay saved. Sign in once for the new Desktop session."];
                if(!desktopSignIn.IsEnabled)explanation.Text+="\n"+L["Close the session from the ⋯ menu and wait for quota operations to finish before changing modes."];
            } else explanation.Text=selected==Agent.Antigravity&&original==null
                ? L["Choose browser sign-in for Google OAuth, or use the official Antigravity CLI. Each account keeps separate sign-in data."]
                : Support(original??new Account{Agent=selected,LaunchMode=effective});
        }
        agent.SelectionChanged+=(_,_)=>{UpdateFields();if(agentValues[agent.SelectedIndex]==Agent.Antigravity)openAfter.IsChecked=true;};desktopSignIn.SelectionChanged+=(_,_)=>UpdateFields();UpdateFields();if(original==null&&agentValues[agent.SelectedIndex]==Agent.Antigravity)openAfter.IsChecked=true;
        signInMethod.SelectionChanged += (_, _) => UpdateFields();
        var save=Button(L[original==null?"Add account":"Save changes"],()=>{
            var selected=agentValues[agent.SelectedIndex];
            var edited=(original??new Account{Agent=selected,Browser=(Browser)browser.SelectedItem})with{Name=name.Text.Trim(),EmailHint=note.Text.Trim(),Color=ProfileColors.Names[color.SelectedIndex],LaunchMode=LaunchMode.Desktop,DesktopSignInPending=selected is Agent.Chatgpt or Agent.Claude?(original==null||original.EffectiveMode==LaunchMode.Browser?true:original.DesktopSignInPending):null,SignInMethod=selected is Agent.Chatgpt or Agent.Claude?(AccountSignInMethod)desktopSignIn.SelectedIndex:null,DefaultAction=defaultAction.SelectedIndex==1?DefaultAction.ConnectSession:DefaultAction.OpenDesktop,ConnectOnStartup=selected==Agent.Chatgpt&&startup.IsChecked==true,SharesLocalWorkspace=selected==Agent.Chatgpt&&shared.IsChecked==true,AntigravityUsesPrivateHome=original?.AntigravityUsesPrivateHome??(original==null&&selected==Agent.Antigravity?true:null),AntigravitySignInMethod=original?.AntigravitySignInMethod??(original==null&&selected==Agent.Antigravity?(AntigravitySignInMethod)signInMethod.SelectedIndex:null)};
            if(original is { SupportsDesktopSignIn:true, EffectiveMode:LaunchMode.Browser } && !desktopSignIn.IsEnabled)
                edited=edited with { LaunchMode=original.LaunchMode, SignInMethod=original.SignInMethod, DesktopSignInPending=original.DesktopSignInPending, SharesLocalWorkspace=original.SharesLocalWorkspace };
            if (edited.UsesPrivateAntigravity)
                edited = edited with { AntigravitySharesLocalProjects = shareAntigravityProject.IsChecked == true, AntigravityLocalProjectFolder = null };
            if(engine.SaveAccount(edited)){dialog.Close();if(original==null&&openAfter.IsChecked==true){if(edited.Agent==Agent.Antigravity)_=engine.ConnectAsync(edited);else if(edited.SupportsDesktopSignIn)_=engine.SignInAccountAsync(edited);else _=engine.OpenAsync(edited);}}
        },true,T);
        save.IsEnabled = !string.IsNullOrWhiteSpace(name.Text) && !engine.ReadOnly;
        name.TextChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(name.Text) && !engine.ReadOnly;
        var body=new DockPanel{LastChildFill=true,Margin=new Thickness(25)};var footer=Row(Button(L["Cancel"],()=>dialog.Close()),save);footer.HorizontalAlignment=HorizontalAlignment.Right;DockPanel.SetDock(footer,Dock.Bottom);body.Children.Add(footer);body.Children.Add(new ScrollViewer{Content=Stack(Text(L[original==null?"Another account.\nKeep your flow.":"Edit profile"],24,true),Space(20),fields),VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Margin=new Thickness(0,0,0,14)});dialog.Content=body;dialog.ShowDialog();
    }
    public void Settings(){ShowManager();var dialog=Dialog(L["Appearance & Language"],650,760);
        void Build(){ThemeManager.ApplyChrome(dialog,T);dialog.Title=L["Appearance & Language"];var stack=Stack(Text(L["Appearance & Language"],24,true),Space(20));
            void Label(string label,UIElement control){stack.Children.Add(Text(L[label],13,true));stack.Children.Add(Space(8));stack.Children.Add(control);stack.Children.Add(Space(18));}
            var language=new ComboBox{ItemsSource=new[]{"Tiếng Việt","English"},SelectedIndex=engine.Preferences.Language=="en"?1:0};language.SelectionChanged+=(_,_)=>{engine.Preferences.Language=language.SelectedIndex==1?"en":"vi";engine.SavePreferences();Build();};Label("Language",language);
            var layout=new ComboBox{ItemsSource=new[]{L["Account cards"],L["Quota overview"]},SelectedIndex=engine.Preferences.WorkspaceLayout==WorkspaceLayout.Cards?0:1};layout.SelectionChanged+=(_,_)=>{engine.Preferences.WorkspaceLayout=layout.SelectedIndex==0?WorkspaceLayout.Cards:WorkspaceLayout.QuotaTable;engine.SavePreferences();};Label("Workspace view",layout);
            stack.Children.Add(Switch(L["Quota-only mode"],engine.Preferences.QuotaOnlyMode,b=>{engine.SetQuotaOnly(b);Build();}));stack.Children.Add(Text(L["Quota-only mode connects ChatGPT, Claude, and Antigravity without opening Desktop. Other agents keep their normal open action."],11,false,T.Secondary));stack.Children.Add(Space(20));
            var themes=new WrapPanel();foreach(var theme in Themes.All){var button=Button(L[theme.Name]+(T.Id==theme.Id?" ✓":""),()=>{engine.Preferences.Theme=theme.Id;engine.SavePreferences();Build();});button.Width=265;button.Margin=new Thickness(0,0,10,10);button.Background=Brush(theme.Surface);button.Foreground=Brush(theme.Ink);button.BorderBrush=Brush(theme.Id==T.Id?theme.Accent:theme.Line);
                if(theme.Seasonal){var label=Text(L[theme.Name]+(T.Id==theme.Id?" ✓":""),12,true,theme.Ink);button.Content=Stack(SeasonalArtwork.Create(theme,214,100),label);button.HorizontalContentAlignment=HorizontalAlignment.Left;}
                System.Windows.Automation.AutomationProperties.SetAutomationId(button,"theme-"+theme.Id);themes.Children.Add(button);}Label("Theme",themes);
            var alerts=new CheckBox{Content=L["Quota notifications"],IsChecked=engine.Preferences.AlertsEnabled};alerts.Checked+=(_,_)=>{engine.Preferences.AlertsEnabled=true;engine.SavePreferences();};alerts.Unchecked+=(_,_)=>{engine.Preferences.AlertsEnabled=false;engine.Preferences.AlertObservations.Clear();engine.SavePreferences();};stack.Children.Add(alerts);
            var threshold=new Slider{Minimum=1,Maximum=95,Value=engine.Preferences.AlertThreshold,IsSnapToTickEnabled=true,TickFrequency=1};var thresholdText=Text(L.Format("Notify at or below %@%% remaining",engine.Preferences.AlertThreshold),12);threshold.ValueChanged+=(_,_)=>{engine.Preferences.AlertThreshold=(int)threshold.Value;engine.Preferences.AlertObservations.Clear();thresholdText.Text=L.Format("Notify at or below %@%% remaining",engine.Preferences.AlertThreshold);engine.SavePreferences();};stack.Children.Add(thresholdText);stack.Children.Add(threshold);
            var recovery=new CheckBox{Content=L["Notify when quota recovers above the threshold"],IsChecked=engine.Preferences.AlertRecovery};recovery.Checked+=(_,_)=>{engine.Preferences.AlertRecovery=true;engine.SavePreferences();};recovery.Unchecked+=(_,_)=>{engine.Preferences.AlertRecovery=false;engine.SavePreferences();};stack.Children.Add(recovery);stack.Children.Add(Text(L["Only fresh quota reads trigger alerts. Reset times alone never trigger recovery notifications."],11,false,T.Secondary));stack.Children.Add(Space(22));
            stack.Children.Add(Text(L["Application executables"],17,true));stack.Children.Add(Text(L["Choose installed executables only when automatic detection cannot find an app. No apps or credentials are downloaded."],11,false,T.Secondary));stack.Children.Add(Space(10));
            foreach(var key in new[]{"chatgpt","claude","codex","claudeCode","antigravityCli","chrome","edge","brave","antigravity"}){var path=Text(engine.Preferences.Executables.GetValueOrDefault(key)??L["Automatic detection"],10,false,T.Secondary);var choose=Button(L["Choose…"],async()=>{var picker=new Microsoft.Win32.OpenFileDialog{Filter="Windows application (*.exe)|*.exe",CheckFileExists=true};if(picker.ShowDialog(dialog)==true){if(await engine.SetExecutableAsync(key,picker.FileName))Build();}});var reset=Button(L["Reset"],async()=>{if(await engine.SetExecutableAsync(key,null))Build();});stack.Children.Add(Text(key=="claudeCode"?"Claude Code CLI":key=="antigravityCli"?"Antigravity CLI":key,12,true));stack.Children.Add(path);stack.Children.Add(Row(choose,reset));stack.Children.Add(Space(12));}
            stack.Children.Add(Text(L["Shared local workspace"],17,true));stack.Children.Add(Text(SharedWorkspace.Source(engine.Preferences),11,false,T.Secondary));stack.Children.Add(Button(L["Choose folder…"],()=>{using var picker=new System.Windows.Forms.FolderBrowserDialog();if(picker.ShowDialog()==System.Windows.Forms.DialogResult.OK){engine.Preferences.Executables["workspace"]=picker.SelectedPath;engine.SavePreferences();Build();}}));stack.Children.Add(Text(L["Enable sharing separately on stopped ChatGPT Desktop profiles. Private history is never overwritten."],11,false,T.Secondary));
            foreach(var (key,label) in new[]{("database","Shared database folder (optional override)"),("artifacts","Shared Work artifacts folder (optional)")}){
                stack.Children.Add(Space(14));stack.Children.Add(Text(L[label],12,true));stack.Children.Add(Text(engine.Preferences.Executables.GetValueOrDefault(key)??L["Automatic detection"],11,false,T.Secondary));
                stack.Children.Add(Row(Button(L["Choose folder…"],()=>{using var picker=new System.Windows.Forms.FolderBrowserDialog();if(picker.ShowDialog()==System.Windows.Forms.DialogResult.OK){engine.Preferences.Executables[key]=picker.SelectedPath;engine.SavePreferences();Build();}}),Button(L["Reset"],()=>{engine.Preferences.Executables.Remove(key);engine.SavePreferences();Build();})));
            }
            var outer=new DockPanel{Margin=new Thickness(26)};var done=Button(L["Done"],()=>dialog.Close(),true,T);done.HorizontalAlignment=HorizontalAlignment.Right;done.Margin=new Thickness(0,15,0,0);DockPanel.SetDock(done,Dock.Bottom);outer.Children.Add(done);outer.Children.Add(new ScrollViewer{Content=stack,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});dialog.Content=outer;
        }Build();dialog.ShowDialog();
    }
    public void Diagnostics(){ShowManager();var dialog=Dialog(L["Session diagnostics"],720,710);async Task Build(){
        await engine.ObserveAsync(false);var stack=Stack(Text(L["Session diagnostics"],23,true),Space(16),Text(engine.LifecycleError??L["Checks use session status, app compatibility, and the last quota result. Passwords, tokens, and conversation contents are not inspected."],11,false,T.Secondary),Space(18));
        foreach(var key in new[]{"chatgpt","claude","codex","chrome","edge","brave","antigravity"}){var path=await engine.Platform.FindExecutableAsync(key);stack.Children.Add(Text(key+": "+(path??L["Not installed"]),11));}
        foreach(var provider in new[]{Agent.Chatgpt,Agent.Claude}){var source=await engine.Platform.FindExecutableAsync(provider.Name().ToLowerInvariant());if(source!=null&&WindowsExecutable.IsStorePath(source)){stack.Children.Add(Text(L.Format("%@ runtime",provider.Name())+": "+StoreRuntime.ExecutableFor(engine.Repository.Root,source),11));}}
        stack.Children.Add(Space(20));foreach(var a in engine.Snapshot.Accounts){var content=Stack(Text(a.Name+" · "+a.Agent.Name(),15,true),Space(6),Text(engine.Status(a),12),Space(8));
            try{engine.Repository.ValidateOwned(engine.Repository.ProfilePath(a),a.Id);if(a.UsesCodexDesktop)engine.Repository.ValidateOwned(engine.Repository.QuotaHome(a),a.Id);content.Children.Add(Text(L["Profile storage verified"],11,false,T.Secondary));}catch(Exception error){content.Children.Add(Text(engine.Message(error),11));}
            if(engine.Errors.TryGetValue(a.Id,out var errorText))content.Children.Add(Text(errorText,11));if(engine.Checks.TryGetValue(a.Id,out var last))content.Children.Add(Text(L.Format("Last check: %@",L.Date(last)),10,false,T.Secondary));
            if(a.UsesCodexDesktop)content.Children.Add(Row(Button(L["Try again"],async()=>{await engine.RefreshAsync(a);await Build();}),Button(L["Restart session…"],()=>Restart(a))));else content.Children.Add(Text(Support(a),11,false,T.Secondary));content.Children.Add(Button(L.Format("Open %@",a.Agent.Name()),()=>_=engine.OpenAsync(a)));var panel=Panel(content,T);panel.Margin=new Thickness(0,0,0,14);stack.Children.Add(panel);}
        var force=Button(L["Force stop all…"],ForceStopAll);force.IsEnabled=!engine.ReadOnly&&!engine.StoppingAll;stack.Children.Add(force);stack.Children.Add(Button(L["Check again"],async()=>await Build()));stack.Children.Add(Button(L["Done"],()=>dialog.Close(),true,T));dialog.Content=new ScrollViewer{Content=new Border{Padding=new Thickness(24),Child=stack},VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        }_=Build();dialog.ShowDialog();
    }
}
