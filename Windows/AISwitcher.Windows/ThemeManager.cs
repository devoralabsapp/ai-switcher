using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using AISwitcher.Core;

namespace AISwitcher.Windows;
internal static class ThemeManager {
    public static SolidColorBrush Brush(string color)=>(SolidColorBrush)new BrushConverter().ConvertFromString(color)!;
    public static void Apply(Theme theme){var r=Application.Current.Resources;
        foreach(var item in new[]{("Canvas",theme.Canvas),("Surface",theme.Surface),("Sidebar",theme.Sidebar),("Ink",theme.Ink),("Secondary",theme.Secondary),("Accent",theme.Accent),("OnAccent",theme.OnAccent),("Line",theme.Line)})r[item.Item1]=Brush(item.Item2);
        r["UIFont"]=new FontFamily(theme.Mono?"Consolas":theme.Retro?"Segoe UI Variable Display":"Segoe UI");r["Outline"]=new Thickness(theme.Retro?2.5:1);r["ButtonRadius"]=new CornerRadius(theme.Retro?100:theme.Mono?3:7);
    }
    public static Border Panel(UIElement child,Theme theme,string? color=null,bool shadow=false){
        var border=new Border{Child=child,Background=Brush(color??theme.Surface),BorderBrush=Brush(theme.Line),BorderThickness=new Thickness(theme.Retro?2.5:1),CornerRadius=new CornerRadius(theme.Retro?16:theme.Mono?3:12),Padding=new Thickness(18)};
        if(theme.Retro&&shadow)border.Effect=new DropShadowEffect{Color=Colors.Black,BlurRadius=0,ShadowDepth=4,Direction=315,Opacity=1};return border;
    }
    public static Button Button(string text,Action action,bool primary=false,Theme? theme=null){var b=new Button{Content=text,Margin=new Thickness(0,0,8,0)};b.Click+=(_,_)=>action();if(primary&&theme!=null){b.Background=Brush(theme.Retro?"#FFD84D":theme.Accent);b.Foreground=Brush(theme.Retro?theme.Ink:theme.OnAccent);b.FontWeight=FontWeights.SemiBold;}return b;}
    public static TextBlock Text(string text,double size=13,bool bold=false,string? color=null){var block=new TextBlock{Text=text,FontSize=size,FontWeight=bold?FontWeights.SemiBold:FontWeights.Normal};if(color!=null)block.Foreground=Brush(color);return block;}
    public static StackPanel Stack(params UIElement[] elements){var panel=new StackPanel();foreach(var e in elements)panel.Children.Add(e);return panel;}
    public static StackPanel Row(params UIElement[] elements){var panel=new StackPanel{Orientation=Orientation.Horizontal};foreach(var e in elements)panel.Children.Add(e);return panel;}
    public static Border Space(double height)=>new(){Height=height};
}
