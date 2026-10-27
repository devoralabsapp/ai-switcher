using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using AISwitcher.Core;
using static AISwitcher.Windows.ThemeManager;

namespace AISwitcher.Windows;
internal sealed record SeasonalPoint(double X,double Y);
internal sealed record SeasonalMark(string Kind,string Color,double X=0,double Y=0,double W=0,double H=0,double Radius=0,double Width=2,double Size=20,string? Stroke=null,string? Text=null,List<SeasonalPoint>? Points=null,bool Closed=false);
internal static class SeasonalArtwork {
    static readonly Dictionary<string,List<SeasonalMark>> Scenes=Assets.Read<Dictionary<string,List<SeasonalMark>>>("SeasonalScenes.json");
    public static FrameworkElement Create(Theme theme,double width=270,double height=170){
        var canvas=new Canvas{Width=360,Height=210,IsHitTestVisible=false};
        foreach(var mark in Scenes.GetValueOrDefault(theme.Id)??[]){
            if(mark.Kind=="text"){
                var label=new TextBlock{Text=mark.Text,FontSize=mark.Size,FontWeight=FontWeights.Black,FontFamily=new FontFamily("Consolas"),Foreground=Brush(mark.Color)};
                Canvas.SetLeft(label,mark.X);Canvas.SetTop(label,mark.Y);canvas.Children.Add(label);continue;
            }
            Shape shape;
            if(mark.Kind=="ellipse")shape=new Ellipse{Width=mark.W,Height=mark.H};
            else if(mark.Kind=="rect")shape=new Rectangle{Width=mark.W,Height=mark.H,RadiusX=mark.Radius,RadiusY=mark.Radius};
            else{
                var geometry=new StreamGeometry();using(var drawing=geometry.Open()){
                    if(mark.Points is {Count:>0} points){drawing.BeginFigure(new Point(points[0].X,points[0].Y),mark.Color!="clear",mark.Closed);drawing.PolyLineTo(points.Skip(1).Select(p=>new Point(p.X,p.Y)).ToArray(),true,false);}
                }
                shape=new Path{Data=geometry,StrokeLineJoin=PenLineJoin.Round,StrokeStartLineCap=PenLineCap.Round,StrokeEndLineCap=PenLineCap.Round};
            }
            shape.Fill=mark.Color=="clear"?Brushes.Transparent:Brush(mark.Color);shape.Stroke=mark.Stroke==null?null:Brush(mark.Stroke);shape.StrokeThickness=mark.Width;
            if(mark.Kind!="path"){Canvas.SetLeft(shape,mark.X);Canvas.SetTop(shape,mark.Y);}canvas.Children.Add(shape);
        }
        return new Viewbox{Child=canvas,Width=width,Height=height,Stretch=Stretch.Uniform,IsHitTestVisible=false,Focusable=false};
    }
    public static FrameworkElement Ribbon(Theme theme){
        var grid=new System.Windows.Controls.Primitives.UniformGrid{Rows=1,Columns=12,Height=3,IsHitTestVisible=false};
        for(var i=0;i<12;i++)grid.Children.Add(new Border{Background=Brush(i%3==0?theme.Companion:theme.Accent),Opacity=i%3==2?0.35:1,CornerRadius=new CornerRadius(2),Margin=new Thickness(2,0,2,0)});
        return grid;
    }
    public static Border Hero(Theme theme,Localizer l){
        var grid=new Grid();grid.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});grid.ColumnDefinitions.Add(new(){Width=new GridLength(270)});
        var copy=Stack(Text(l[theme.SeasonalLabel],10,true,theme.Accent),Space(14),Text(l["Multiple accounts.\nOne click."],31,true),Space(12),Text(l["Sign in to each account once.\nSwitch freely, keep your conversations going."],12,false,theme.Secondary));copy.VerticalAlignment=VerticalAlignment.Center;grid.Children.Add(copy);
        var art=Create(theme);Grid.SetColumn(art,1);grid.Children.Add(art);
        var body=Stack(grid,Space(12),Ribbon(theme));var panel=Panel(body,theme);panel.CornerRadius=new CornerRadius(theme.Id=="blackFriday"?4:20);panel.Padding=new Thickness(22);panel.Margin=new Thickness(0,0,4,28);
        panel.Background=new LinearGradientBrush(((SolidColorBrush)Brush(theme.Surface)).Color,((SolidColorBrush)Brush(theme.Canvas)).Color,45);return panel;
    }
}
