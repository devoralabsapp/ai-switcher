using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using AISwitcher.Core;
using static AISwitcher.Windows.ThemeManager;

namespace AISwitcher.Windows;
internal sealed partial class MainWindow {
    public async void ContinueChat(Account account){
        ShowManager();await engine.ContinueChatAsync(account,(identity,load)=>{
            var dialog=Dialog(L["Continue chat with this account…"],690,690);LocalChat? selected=null;var chats=new List<LocalChat>();string? cursor=null;bool loading=false,closed=false;
            var search=new TextBox();var list=new StackPanel();var status=Text("",11,false,T.Secondary);var more=Button(L["Load more"],()=>{});var cancel=Button(L["Cancel"],()=>dialog.Close());
            void Render(){list.Children.Clear();foreach(var chat in chats.Where(x=>string.IsNullOrWhiteSpace(search.Text)||(x.Title+" "+x.Cwd).Contains(search.Text,StringComparison.CurrentCultureIgnoreCase))){
                var button=Button("",()=>{selected=chat;dialog.Close();});button.Content=Stack(Text(chat.Title,13,true),Text(chat.Cwd,10,false,T.Secondary));button.HorizontalContentAlignment=HorizontalAlignment.Left;button.Margin=new Thickness(0,0,0,8);list.Children.Add(button);
            }}
            async Task Load(){if(loading||closed)return;loading=true;more.IsEnabled=false;status.Text=L["Working…"];
                try{var page=await load(cursor);if(closed)return;chats.AddRange(page.Chats);cursor=page.NextCursor;Render();more.Visibility=cursor==null?Visibility.Collapsed:Visibility.Visible;status.Text=chats.Count==0?L["No local conversations found."]:"";}
                catch(Exception error){if(!closed)status.Text=engine.Message(error);}finally{loading=false;if(!closed)more.IsEnabled=true;}
            }
            more.Click+=async(_,_)=>await Load();search.TextChanged+=(_,_)=>Render();dialog.Closed+=(_,_)=>closed=true;dialog.Loaded+=async(_,_)=>await Load();
            var top=Stack(Text(L["Continue chat with this account…"],23,true),Space(8),Text(account.Name+" · "+(identity.Email??L["No data yet"]),13,true),Space(12),Text(L["Choose a local chat. Codex creates a new branch with this account and keeps the original history. No message is sent automatically."],12),Space(16),Text(L["Search loaded conversations"],11,false,T.Secondary),search,Space(12));
            var footer=Stack(status,Row(more,cancel));var body=new DockPanel{Margin=new Thickness(24)};DockPanel.SetDock(top,Dock.Top);body.Children.Add(top);DockPanel.SetDock(footer,Dock.Bottom);body.Children.Add(footer);body.Children.Add(new ScrollViewer{Content=list,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});dialog.Content=body;dialog.ShowDialog();return Task.FromResult(selected);
        });
    }
}
