using System;
using System.Drawing;
using System.Runtime.InteropServices;
using Forms=System.Windows.Forms;

namespace AISwitcher.Windows;
/// Native tray messages keep quota alerts silent without altering Windows settings.
internal sealed class SilentTrayIcon:Forms.NativeWindow,IDisposable {
    const int Callback=0x8001;bool visible;Icon? icon;string text="AI Switcher";
    readonly uint taskbarCreated=RegisterWindowMessage("TaskbarCreated");
    public event EventHandler? DoubleClick;public event EventHandler? BalloonTipClicked;
    public Forms.ContextMenuStrip? ContextMenuStrip{get;set;}
    public SilentTrayIcon(){CreateHandle(new Forms.CreateParams{Caption="AI Switcher tray"});}
    public string Text{get=>text;set{text=value;Update();}}
    public Icon? Icon{get=>icon;set{icon=value;Update();}}
    public bool Visible{get=>visible;set{if(visible==value)return;visible=value;var data=Data();ShellNotifyIcon(value?0u:2u,ref data);}}
    NotifyData Data()=>new(){Size=Marshal.SizeOf<NotifyData>(),Window=Handle,Id=1,Flags=1|2|4,CallbackMessage=Callback,Icon=icon?.Handle??IntPtr.Zero,Tip=text,Info="",InfoTitle=""};
    void Update(){if(!visible)return;var data=Data();ShellNotifyIcon(1,ref data);}
    public void ShowBalloonTip(int timeout,string title,string body,Forms.ToolTipIcon kind){var data=Data();data.Flags=0x10;data.InfoTitle=title.Length>63?title[..63]:title;data.Info=body.Length>255?body[..255]:body;data.Timeout=timeout;data.InfoFlags=1|0x10;ShellNotifyIcon(1,ref data);}
    protected override void WndProc(ref Forms.Message message){
        if((uint)message.Msg==taskbarCreated&&visible){var data=Data();ShellNotifyIcon(0,ref data);}
        if(message.Msg==Callback){var kind=(int)message.LParam;
            if(kind==0x203)DoubleClick?.Invoke(this,EventArgs.Empty);
            if(kind==0x405)BalloonTipClicked?.Invoke(this,EventArgs.Empty);
            if(kind is 0x205 or 0x7b){SetForegroundWindow(Handle);ContextMenuStrip?.Show(Forms.Cursor.Position);}
        }
        base.WndProc(ref message);
    }
    public void Dispose(){Visible=false;ContextMenuStrip?.Dispose();icon?.Dispose();DestroyHandle();}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct NotifyData {
        public int Size;public IntPtr Window;public uint Id;public uint Flags;public int CallbackMessage;public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)]public string Tip;
        public uint State;public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string Info;
        public int Timeout;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)]public string InfoTitle;
        public uint InfoFlags;public Guid Guid;public IntPtr BalloonIcon;
    }
    [DllImport("shell32.dll",EntryPoint="Shell_NotifyIconW",CharSet=CharSet.Unicode)]static extern bool ShellNotifyIcon(uint message,ref NotifyData data);
    [DllImport("user32.dll")]static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern uint RegisterWindowMessage(string name);
}
