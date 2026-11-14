using System;
using System.Windows;
using System.Windows.Controls;

namespace AISwitcher.Windows;
internal sealed class AccountColumnsPanel:Panel {
    const double MinimumWidth=254,MaximumWidth=320,Gap=14;
    static (int Count,double Width) Columns(double width,int children){
        if(!double.IsFinite(width))width=MinimumWidth;
        width=Math.Max(0,width);
        var count=Math.Max(1,(int)Math.Min(Math.Max(1,children),(width+Gap)/(MinimumWidth+Gap)));
        return (count,Math.Min(MaximumWidth,Math.Max(0,(width-(count-1)*Gap)/count)));
    }
    protected override Size MeasureOverride(Size available){
        var (count,width)=Columns(available.Width,InternalChildren.Count);var heights=new double[count];
        for(var i=0;i<InternalChildren.Count;i++){
            var card=InternalChildren[i];card.Measure(new Size(width,double.PositiveInfinity));heights[i%count]+=card.DesiredSize.Height+Gap;
        }
        return new Size(count*width+(count-1)*Gap,Math.Max(0,Maximum(heights)-Gap));
    }
    protected override Size ArrangeOverride(Size final){
        var (count,width)=Columns(final.Width,InternalChildren.Count);var heights=new double[count];
        for(var i=0;i<InternalChildren.Count;i++){
            var card=InternalChildren[i];var column=i%count;
            card.Arrange(new Rect(column*(width+Gap),heights[column],width,card.DesiredSize.Height));heights[column]+=card.DesiredSize.Height+Gap;
        }
        return final;
    }
    static double Maximum(double[] values){double result=0;foreach(var value in values)result=Math.Max(result,value);return result;}
}
