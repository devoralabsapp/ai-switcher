using System;
using System.Collections.Generic;

using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using AISwitcher.Core;
using static AISwitcher.Windows.ThemeManager;

namespace AISwitcher.Windows;
internal sealed partial class MainWindow:Window {
    readonly AppEngine engine;
    string workspaceFilter="all",search="",currentTheme="",currentLanguage="",signature="";
    TextBox searchBox=null!;StackPanel sidebar=null!,workspace=null!;
    public bool Exiting { get; set; }
    public MainWindow(AppEngine engine){
        this.engine=engine;Style=(Style)Application.Current.FindResource(typeof(Window));SourceInitialized+=(_,_)=>ThemeManager.ApplyChrome(this,T);Title="AI Switcher";Width=1160;Height=850;MinWidth=1000;MinHeight=700;
        WindowStartupLocation=WindowStartupLocation.CenterScreen;
        engine.Changed+=Update;engine.Error+=message=>Notice(L["AI Switcher"],message);
        Closing+=(_,e)=>{if(!Exiting){e.Cancel=true;Hide();}};
        PreviewKeyDown+=(_,e)=>{
            if(Keyboard.Modifiers!=ModifierKeys.Control)return;
            if(e.Key==Key.N){EditAccount();e.Handled=true;}
            if(e.Key==Key.K){searchBox.Focus();e.Handled=true;}
            if(e.Key==Key.OemComma){Settings();e.Handled=true;}
            if(e.Key>=Key.D1&&e.Key<=Key.D9){var a=Visible().ElementAtOrDefault(e.Key-Key.D1);if(a!=null)_=engine.DefaultAsync(a);e.Handled=true;}
        };
        Render();
    }
    Localizer L=>engine.L;Theme T=>engine.Theme;
    public void ShowManager(){Show();WindowState=WindowState.Normal;Activate();}
    IEnumerable<Account> Visible(){IEnumerable<Account> result=engine.Snapshot.Accounts;
        if(engine.Preferences.AgentFilter is { } agent)result=result.Where(x=>x.Agent==agent);
        if(workspaceFilter=="favorites")result=result.Where(x=>x.IsFavorite);
        if(workspaceFilter=="recent")result=result.Where(x=>x.LastOpenedAt!=null).OrderByDescending(x=>x.LastOpenedAt);
        if(!string.IsNullOrWhiteSpace(search))result=result.Where(x=>(x.Name+" "+x.EmailHint+" "+x.Agent.Name()).Contains(search,StringComparison.CurrentCultureIgnoreCase));return result;}
    void Update(){if(!Dispatcher.CheckAccess()){Dispatcher.Invoke(Update);return;}
        var next=System.Text.Json.JsonSerializer.Serialize(engine.Snapshot,Json.Options)+System.Text.Json.JsonSerializer.Serialize(engine.Preferences,Json.Options)+engine.StoppingAll+workspaceFilter+search+engine.LifecycleError+string.Join("|",engine.Snapshot.Accounts.Select(a=>engine.Status(a)+":"+engine.Running(a)+":"+engine.CanConnect(a)))+string.Join("|",engine.Errors.Values);
        if(signature==next)return;signature=next;
        if(currentTheme!=engine.Preferences.Theme||currentLanguage!=engine.Preferences.Language){Render();return;}RenderSidebar();RenderWorkspace();}
    void Render(){ThemeManager.Apply(T);ThemeManager.ApplyChrome(this,T);currentTheme=engine.Preferences.Theme;currentLanguage=engine.Preferences.Language;
        var outer=new Grid();outer.ColumnDefinitions.Add(new(){Width=new GridLength(230)});outer.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});
        sidebar=new StackPanel{Margin=new Thickness(18,26,18,18)};
        var sideScroll=new ScrollViewer{Content=sidebar,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Background=Brush(T.Sidebar)};
        outer.Children.Add(sideScroll);
        var right=new Grid();right.RowDefinitions.Add(new(){Height=GridLength.Auto});right.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});right.RowDefinitions.Add(new(){Height=GridLength.Auto});Grid.SetColumn(right,1);outer.Children.Add(right);
        var toolbar=new DockPanel{Margin=new Thickness(26,16,26,16),LastChildFill=true};
        searchBox=new TextBox{Text=search,Width=245,ToolTip=L["Find accounts"]};AutomationProperties.SetAutomationId(searchBox,"accountSearch");searchBox.TextChanged+=(_,_)=>{search=searchBox.Text;RenderWorkspace();};DockPanel.SetDock(searchBox,Dock.Right);toolbar.Children.Add(searchBox);
        toolbar.Children.Add(Text((T.Mono?"~/accounts $ ai-switcher":L["Workspace"])+"  ›  "+(engine.Preferences.AgentFilter?.Name()??L["All agents"]),12));right.Children.Add(toolbar);
        workspace=new StackPanel{Margin=new Thickness(28,16,28,24)};var scroll=new ScrollViewer{Content=workspace,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};Grid.SetRow(scroll,1);right.Children.Add(scroll);
        var footer=Text("●  "+L["Ready when you are"]+"                                      AI Switcher 1.4 · Windows",10,false,T.Secondary);footer.Margin=new Thickness(28,10,20,10);Grid.SetRow(footer,2);right.Children.Add(footer);Content=outer;
        RenderSidebar();RenderWorkspace();
    }
    void NavStyle(Button button,bool selected,string fill){button.Background=selected?Brush(fill):Brush("#00000000");button.BorderThickness=new Thickness(selected?(T.Retro?2.5:1):0);button.FontWeight=selected?FontWeights.SemiBold:FontWeights.Normal;}
    void RenderSidebar(){sidebar.Children.Clear();sidebar.Children.Add(Text("⇅  AI Switcher",21,true));sidebar.Children.Add(Text(L["One click to your account"],11,false,T.Secondary));sidebar.Children.Add(Space(28));if(T.Seasonal){sidebar.Children.Add(Text(L[T.Name],11,true,T.Accent));sidebar.Children.Add(Space(16));}sidebar.Children.Add(Text(L["YOUR WORKSPACE"],10,true,T.Secondary));sidebar.Children.Add(Space(10));
        foreach(var (id,key) in new[]{("all","All accounts"),("favorites","Favorites"),("recent","Recent")}){var selected=workspaceFilter==id;var button=Button(L[key]+(id=="all"?"   "+engine.Snapshot.Accounts.Count:""),()=>{workspaceFilter=id;Update();});button.Margin=new Thickness(0,0,0,7);button.HorizontalContentAlignment=HorizontalAlignment.Left;NavStyle(button,selected,T.Retro?"#B4EDC5":T.Surface);sidebar.Children.Add(button);}
        sidebar.Children.Add(Space(22));sidebar.Children.Add(Text(L["AI AGENTS"],10,true,T.Secondary));sidebar.Children.Add(Space(10));
        var all=Button(L["All agents"]+"   "+engine.Snapshot.Accounts.Count,()=>{engine.SetAgent(null);Render();});all.Margin=new Thickness(0,0,0,5);all.HorizontalContentAlignment=HorizontalAlignment.Left;NavStyle(all,engine.Preferences.AgentFilter==null,T.Retro?"#A8D8F0":T.Surface);sidebar.Children.Add(all);
        foreach(var agent in Enum.GetValues<Agent>()){var button=Button(agent.Name()+"   "+engine.Snapshot.Accounts.Count(x=>x.Agent==agent),()=>{engine.SetAgent(agent);Render();});button.Margin=new Thickness(0,0,0,5);button.HorizontalContentAlignment=HorizontalAlignment.Left;NavStyle(button,engine.Preferences.AgentFilter==agent,T.Retro?"#A8D8F0":T.Surface);AutomationProperties.SetAutomationId(button,"agent-filter-"+agent.ToString().ToLowerInvariant());sidebar.Children.Add(button);}
        if(engine.Snapshot.Accounts.FirstOrDefault(x=>x.Id==engine.Snapshot.LastOpenedId) is { } last){sidebar.Children.Add(Space(18));sidebar.Children.Add(Text(L["OPEN AGAIN"],10,true,T.Secondary));sidebar.Children.Add(Button(last.Name,()=>_=engine.DefaultAsync(last)));}
        sidebar.Children.Add(Space(28));foreach(var (title,action) in new(string,Action)[]{("Appearance & Language",Settings),("How it works",Guide),("Session diagnostics",Diagnostics),("Local data",RevealData)}){var button=Button(L[title],action);button.Margin=new Thickness(0,0,0,8);button.HorizontalContentAlignment=HorizontalAlignment.Left;NavStyle(button,false,T.Surface);sidebar.Children.Add(button);}
        var force=Button(L["Force stop all…"],ForceStopAll);force.IsEnabled=!engine.ReadOnly&&!engine.StoppingAll;force.ToolTip=L["Force stop all account processes"];AutomationProperties.SetAutomationId(force,"forceStopAll");sidebar.Children.Add(force);
        sidebar.Children.Add(Space(14));sidebar.Children.Add(Text(L["Choose an agent to view its accounts and supported features."],10,false,T.Secondary));
    }
    void RenderWorkspace(){workspace.Children.Clear();
        if(engine.Preferences.WorkspaceLayout==WorkspaceLayout.Cards){
            if(T.Seasonal)workspace.Children.Add(SeasonalArtwork.Hero(T,L));
            else {var hero=Stack(Text(L["FEWER CLICKS. KEEP YOUR FLOW."],10,true,T.Retro?T.Ink:T.Accent),Space(16),Text(L["Multiple accounts.\nOne click."],32,true),Space(12),Text(L["Sign in to each account once.\nSwitch freely, keep your conversations going."],12,false,T.Secondary));
            var panel=Panel(hero,T,T.Retro?"#FFD84D":T.Canvas,T.Retro);panel.Padding=new Thickness(22);panel.Margin=new Thickness(0,0,4,28);workspace.Children.Add(panel);}
        }
        if(engine.ReadOnly){var warning=Panel(Stack(Text(engine.LoadError??L["Could not read data. The existing file has been preserved."],13,true),Button(L["Open folder"],RevealData)),T);warning.Margin=new Thickness(0,0,0,18);workspace.Children.Add(warning);}
        var header=new DockPanel{LastChildFill=true,Margin=new Thickness(0,0,0,22)};
        var add=Button("＋ "+L["Add account"],()=>EditAccount(),true,T);add.IsEnabled=!engine.ReadOnly&&!engine.StoppingAll;AutomationProperties.SetAutomationId(add,"addAccount");
        var toggle=Switch(L["Quota-only mode"],engine.Preferences.QuotaOnlyMode,engine.SetQuotaOnly);AutomationProperties.SetAutomationId(toggle,"quotaOnlyMode");toggle.Margin=new Thickness(0,0,16,0);
        var actions=Row(toggle,add);actions.VerticalAlignment=VerticalAlignment.Center;DockPanel.SetDock(actions,Dock.Right);header.Children.Add(actions);
        header.Children.Add(Stack(Text(L[workspaceFilter=="favorites"?"Favorites":workspaceFilter=="recent"?"Recent":"All accounts"]+"   "+Visible().Count(),18,true),Space(4),Text(L["Profiles grouped by your AI agents."],11,false,T.Secondary)));workspace.Children.Add(header);
        var visible=Visible().ToArray();
        if(visible.Length==0){var content=Stack(Text(L[engine.Snapshot.Accounts.Count==0?"Add your first account":"No matching accounts"],19,true),Space(10),Text(L["Personal, work, or study — give each account a recognizable name."],12,false,T.Secondary),Space(16),Button(L["Add account"],()=>EditAccount(),true,T));workspace.Children.Add(Panel(content,T));return;}
        if(engine.Preferences.WorkspaceLayout==WorkspaceLayout.QuotaTable){RenderTable(visible);return;}
        var wrap=new WrapPanel{Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Stretch};foreach(var a in visible){var card=AccountCard(a);card.Width=254;card.Margin=new Thickness(0,0,14,18);wrap.Children.Add(card);}workspace.Children.Add(wrap);
    }
    Border AccountCard(Account a){
        var favorite=Button(a.IsFavorite?"★":"☆",()=>engine.ToggleFavorite(a));favorite.Padding=new Thickness(5,3,5,3);var menu=Button("⋯",()=>{});menu.Padding=new Thickness(7,3,7,3);var context=AccountMenu(a);menu.ContextMenu=context;menu.Click+=(_,_)=>{context.PlacementTarget=menu;context.IsOpen=true;};
        var top=new DockPanel();var controls=Row(favorite,menu);DockPanel.SetDock(controls,Dock.Right);top.Children.Add(controls);top.Children.Add(Text(a.Name.Split(' ',StringSplitOptions.RemoveEmptyEntries).Select(x=>x[0]).Take(2).Aggregate("",(s,c)=>s+char.ToUpper(c)),19,true));
        var stack=Stack(top,Space(18),Text(a.Name,17,true),Space(4),Text(string.IsNullOrWhiteSpace(a.EmailHint)?a.Agent.Name():a.EmailHint,11,false,T.Secondary),Space(16),Text(a.Agent.Name()+" · "+(a.EffectiveMode==LaunchMode.Desktop?L["Desktop"]:a.Browser.ToString()),10,false,T.Secondary),Space(8),Text(engine.Status(a),10,true),Space(16));
        if(T.Seasonal){stack.Children.Insert(0,SeasonalArtwork.Ribbon(T));stack.Children.Insert(1,Space(12));}
        if(a.Agent.HasQuota())stack.Children.Add(QuotaSummary(a,false));else stack.Children.Add(Text(Support(a),11,false,T.Secondary));
        stack.Children.Add(Space(18));var open=Button(engine.DefaultTitle(a)+"  ↗",()=>_=engine.DefaultAsync(a));open.IsEnabled=!engine.StoppingAll&&!engine.Busy.Contains(a.Id);open.HorizontalAlignment=HorizontalAlignment.Stretch;stack.Children.Add(open);
        var panel=Panel(stack,T,ProfileColors.Pale(a.Color,T),true);panel.ContextMenu=AccountMenu(a);return panel;
    }
    string Support(Account a)=>a.Agent.IsShared()?L["Antigravity quota uses the official CLI and shared application sign-in."]:a.Agent==Agent.Claude?L["Claude quota uses Claude Code sign-in in this profile. Desktop and browser sessions remain separate."]:L["Separate browser sign-in for each profile. Quota and background connections are not available for this agent."];
    ContextMenu AccountMenu(Account a){var menu=new ContextMenu();bool busy=engine.StoppingAll||engine.Busy.Contains(a.Id);
        void Item(string text,Action action,bool enabled=true){var item=new MenuItem{Header=text,IsEnabled=enabled};item.Click+=(_,_)=>action();menu.Items.Add(item);}
        Item(L.Format("Open %@",a.Agent.Name()),()=>_=engine.OpenAsync(a),!busy);
        if(a.Agent.ProviderQuota()){Item(L["Connect account session"],()=>_=engine.ConnectAsync(a),engine.CanConnect(a));Item(L["Refresh quota"],()=>_=engine.RefreshAsync(a),!busy);}
        if(a.UsesCodexDesktop){Item(L["Connect account session"],()=>_=engine.ConnectAsync(a),engine.CanConnect(a));Item(L["Refresh quota"],()=>_=engine.RefreshAsync(a),!busy);Item(L["Restart session…"],()=>Restart(a),!busy);}
        if(a.Agent.HasQuota())Item(L[a.Agent.ProviderQuota()?"Details":"Codex quota…"],()=>QuotaDetails(a));
        menu.Items.Add(new Separator());Item(L["Edit profile…"],()=>EditAccount(a),!busy);Item(L["Close account session…"],()=>Close(a),!busy&&(!a.Agent.IsShared()||engine.Provider.Connected.Contains(a.Id))&&engine.Running(a));
        Item(L["Delete local profile…"],()=>Delete(a),!busy);return menu;
    }
    void AddProviderInstallation(StackPanel stack,Account a,Action? refresh=null){
        if(engine.InstallingProviders.Contains(a.Agent)){
            stack.Children.Add(Text(L.Format("Installing %@ CLI…",a.Agent.Name()),12,true));
            stack.Children.Add(Text(L["Installation is running in PowerShell. This app will connect when it finishes."],11,false,T.Secondary));
        }else if(!engine.Provider.HasExecutable(a.Agent)){
            var install=Button(L["Install & connect"],async()=>{var pending=engine.InstallProviderAsync(a);refresh?.Invoke();await pending;refresh?.Invoke();},true,T);
            install.IsEnabled=!engine.ReadOnly&&!engine.Busy.Contains(a.Id);stack.Children.Add(install);
        }
        if(engine.InstallationErrors.TryGetValue(a.Agent,out var message))stack.Children.Add(Text(message,11,false,T.Secondary));
    }
    StackPanel QuotaSummary(Account a,bool all){var stack=new StackPanel();if(!all&&a.Agent.ProviderQuota())AddProviderInstallation(stack,a);var connection=a.Connection;var now=DateTimeOffset.UtcNow;
        if(connection==null){stack.Children.Add(Text(L[a.Agent.ProviderQuota()?"Connect the official CLI session to read subscription quota. No model prompt is sent.":a.UsesCodexDesktop?"For a new or signed-out profile, use Open ChatGPT Desktop once to sign in. Connecting a session never opens a Desktop window.":"No data yet"],11,false,T.Secondary));if(a.UsesCodexDesktop||a.Agent.ProviderQuota()){var connect=Button(L["Connect account session"],()=>_=engine.ConnectAsync(a));connect.IsEnabled=engine.CanConnect(a);stack.Children.Add(connect);}return stack;}
        stack.Children.Add(Text("◉ "+(a.Agent.ProviderQuota()?L.Format("%@ quota",a.Agent.Name()):L["Codex quota"]),12,true));stack.Children.Add(Space(8));stack.Children.Add(Text(connection.Identity.Email??L[a.Agent.ProviderQuota()?"Shared application sign-in":"Verified Codex identity"],11,false,T.Secondary));
        if(connection.Quota is not { } quota){stack.Children.Add(Text(L["No data yet"]));return stack;}
        foreach(var bucket in all?quota.Limits.Buckets:quota.Limits.Buckets.Take(1)){
            if(all)stack.Children.Add(Text(bucket.Value.LimitName??bucket.Key,12,true));
            foreach(var window in new[]{bucket.Value.Primary,bucket.Value.Secondary}.OfType<QuotaWindow>()){
                stack.Children.Add(Space(9));var remaining=window.Expired(now)?null:window.Remaining;
                stack.Children.Add(Text(window.Duration(L)+" · "+(remaining.HasValue?L.Format("%@%% remaining",remaining.Value.ToString("0.#",L.Culture)):!window.Expired(now)&&window.RemainingAmount is double amount?L.Format("%@ remaining",amount.ToString("0.#",L.Culture)):L["No data yet"]),11));
                if(remaining.HasValue)stack.Children.Add(new ProgressBar{Minimum=0,Maximum=100,Value=remaining??0,Height=5,Margin=new Thickness(0,5,0,4),Foreground=Brush(T.Accent),Background=Brush(T.Line)});
                if(window.Reset is { } reset)stack.Children.Add(Text(L.Format("Reset: %@",L.Date(reset)),10,false,T.Secondary));
            }
        }
        stack.Children.Add(Space(10));stack.Children.Add(Text(L.Format("Last read: %@",L.Date(quota.FetchedAt)),10,false,T.Secondary));
        if(quota.IsStale(now)||engine.Errors.ContainsKey(a.Id))stack.Children.Add(Text(L["Stale data · refresh needed"],10,true));return stack;
    }
    void RenderTable(Account[] accounts){var table=new StackPanel();
        var headings=new StackPanel{Orientation=Orientation.Horizontal};foreach(var (key,title,width) in new[]{(SortKey.Name,"Account",185),(SortKey.PrimaryRemaining,"Short window",115),(SortKey.SecondaryRemaining,"Long window",115),(SortKey.NextReset,"Next reset",150),(SortKey.LastUpdated,"Last updated",150)}){var button=Button(L[title]+(engine.Preferences.QuotaSortKey==key?(engine.Preferences.QuotaSortAscending?" ↑":" ↓"):""),()=>{engine.Preferences.QuotaSortAscending=engine.Preferences.QuotaSortKey==key?!engine.Preferences.QuotaSortAscending:true;engine.Preferences.QuotaSortKey=key;engine.SavePreferences();});button.Width=width;headings.Children.Add(button);}table.Children.Add(headings);
        foreach(var a in QuotaOverview.Sort(accounts,engine.Preferences,engine.Errors.Keys.ToHashSet())){var bucket=a.Connection?.Quota?.Limits.Buckets.FirstOrDefault().Value;string Remaining(QuotaWindow? w)=>!a.Agent.HasQuota()?L["Not available"]:w?.Remaining is double value&&w.Expired(DateTimeOffset.UtcNow)==false?value.ToString("0.#",L.Culture)+"%":w?.Expired(DateTimeOffset.UtcNow)==false&&w.RemainingAmount is double amount?L.Format("%@ remaining",amount.ToString("0.#",L.Culture)):L["No data yet"];
            var row=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,10,0,10)};
            var name=Button(a.Name,()=>QuotaDetails(a));name.Width=185;row.Children.Add(name);
            foreach(var (text,width) in new[]{(Remaining(bucket?.Primary),115),(Remaining(bucket?.Secondary),115),(new[]{bucket?.Primary?.Reset,bucket?.Secondary?.Reset}.Where(x=>x>DateTimeOffset.UtcNow).Min() is { } reset?L.Date(reset):L["No data yet"],150),(a.Connection?.Quota is { } quota?L.Date(quota.FetchedAt):L["No data yet"],150)}){var cell=Text(text,11);cell.Width=width;cell.Margin=new Thickness(0,8,8,0);row.Children.Add(cell);}
            var action=Button(a.Agent.HasQuota()?L["Details"]:L["Open agent"],()=>QuotaDetails(a));row.Children.Add(action);row.ContextMenu=AccountMenu(a);table.Children.Add(row);table.Children.Add(Text(engine.Status(a)+(a.Connection?.Quota?.IsStale(DateTimeOffset.UtcNow)==true?" · "+L["Stale data · refresh needed"]:""),10,false,T.Secondary));}
        workspace.Children.Add(new ScrollViewer{Content=table,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled});
    }
    public void ForceStopAll(){if(Ask(L["Force stop all account processes?"],L["This immediately stops Desktop windows, browsers and background connections belonging to AI Switcher accounts. Unsaved drafts may be lost. Apps opened separately and account sign-ins are kept."],L["Force stop all"]))_=engine.ForceStopAllAsync();}
    public void Close(Account a){if(Ask(L["Close this account session?"],L.Format("Windows for “%@” will close. Send or copy any drafts first. Your login is kept for next time.",a.Name),L["Close session"]))_=engine.CloseAsync(a);}
    public void Restart(Account a){if(Ask(L["Restart this account session?"],L.Format("Windows for “%@” will close. Send or copy drafts first. Only this profile restarts in the background; your saved sign-in is kept.",a.Name),L["Restart in background"]))_=engine.RestartAsync(a);}
    void Delete(Account a){if(Ask(L["Delete this local profile?"],L.Format("The “%@” profile and its local Desktop, browser, and backend data will be deleted. Service accounts and conversation history are kept.",a.Name),L["Delete profile"]))_=engine.DeleteAsync(a);}
    void RevealData(){Directory.CreateDirectory(engine.Repository.Root);System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe"){ArgumentList={engine.Repository.Root},UseShellExecute=false});}
    void Guide()=>Notice(L["How it works"],L["Windows quick start"]);
    static CheckBox Switch(string text,bool value,Action<bool> changed){
        var box=new CheckBox{Content=text,IsChecked=value,VerticalAlignment=VerticalAlignment.Center};
        box.Template=(ControlTemplate)System.Windows.Markup.XamlReader.Parse("<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='CheckBox'><StackPanel Orientation='Horizontal'><ContentPresenter VerticalAlignment='Center' Margin='0,0,10,0'/><Border x:Name='Track' Width='42' Height='24' CornerRadius='12' Background='{DynamicResource Line}'><Ellipse x:Name='Knob' Width='18' Height='18' Fill='White' HorizontalAlignment='Left' Margin='3'/></Border></StackPanel><ControlTemplate.Triggers><Trigger Property='IsChecked' Value='True'><Setter TargetName='Knob' Property='HorizontalAlignment' Value='Right'/><Setter TargetName='Track' Property='Background' Value='{DynamicResource Accent}'/></Trigger></ControlTemplate.Triggers></ControlTemplate>");
        box.Checked+=(_,_)=>changed(true);box.Unchecked+=(_,_)=>changed(false);return box;
    }
}
